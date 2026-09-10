--!nonstrict
-- Bridge discovery and formatting, shared by service.luau and panel.luau.
--
-- Both entries talk to the same sidecar and neither owns it, so everything about
-- "where is it and is it up" lives here rather than being written twice with two
-- slightly different answers.

local M = {}

M.PLUGIN_ID = "duchovs/claude-code"
M.PANEL = M.PLUGIN_ID .. ":console"

-- ── Bridge endpoint ─────────────────────────────────────────────────────────

-- The sidecar writes {pid, port, token} here on startup, 0600. Matches
-- runtime_dir() in bridge.py; keep the two in step.
local function lockPath(): string
  local base = noctalia.getenv("XDG_RUNTIME_DIR")
  if base == nil or base == "" then
    base = noctalia.getenv("TMPDIR")
  end
  if base == nil or base == "" then
    base = "/tmp"
  end
  return base .. "/noctalia-claude-code/bridge.json"
end

-- Cached so a render pass does not hit the filesystem per frame. Invalidated
-- whenever a request against it fails, which is the only signal we get that the
-- sidecar went away.
local cachedEndpoint = nil

function M.forgetEndpoint()
  cachedEndpoint = nil
end

function M.endpoint()
  if cachedEndpoint ~= nil then
    return cachedEndpoint
  end
  local contents = noctalia.readFile(lockPath())
  if contents == nil or contents == "" then
    return nil
  end
  local parsed = noctalia.json.decode(contents)
  if type(parsed) ~= "table" or parsed.port == nil or parsed.token == nil then
    return nil
  end
  cachedEndpoint = { port = parsed.port, token = tostring(parsed.token), pid = parsed.pid }
  return cachedEndpoint
end

-- ── Working directory ───────────────────────────────────────────────────────

-- /cwd has to persist somewhere, and the plugin API has no setter for its own
-- settings — getConfig reads, nothing writes. So the last directory chosen from
-- the console lives in the plugin's data dir and takes precedence over the
-- configured default; clearing it falls back to the setting, then to $HOME.
local function statePath(): string?
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/console.json"
end

function M.rememberWorkingDir(path: string)
  local target = statePath()
  if target == nil then
    return
  end
  local encoded = noctalia.json.encode({ working_dir = path })
  if encoded ~= nil then
    noctalia.writeFile(target, encoded)
  end
end

function M.effectiveWorkingDir(): string
  local target = statePath()
  if target ~= nil then
    local raw = noctalia.readFile(target)
    if raw ~= nil and raw ~= "" then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" and type(decoded.working_dir) == "string" and decoded.working_dir ~= "" then
        return decoded.working_dir
      end
    end
  end
  local configured = noctalia.getConfig("working_dir")
  if type(configured) == "string" and configured ~= "" then
    return noctalia.expandPath(configured)
  end
  return ""
end

-- ── Launching ───────────────────────────────────────────────────────────────

-- Idempotent: bridge.py checks the lock and exits successfully if a healthy
-- instance already answers, so the panel and the service may both call this
-- without coordinating.
function M.launch()
  local dir = noctalia.pluginDir()
  if dir == nil then
    return false
  end
  if not noctalia.commandExists("python3") then
    return false
  end

  local argv = {
    "python3",
    dir .. "/bridge.py",
    "--binary", tostring(noctalia.getConfig("binary") or "claude"),
    "--working-dir", M.effectiveWorkingDir(),
    "--permission-prompts", tostring(noctalia.getConfig("permission_prompts") or "ask"),
    "--permission-timeout", tostring(noctalia.getConfig("permission_timeout") or 120),
    "--idle-minutes", tostring(noctalia.getConfig("idle_shutdown_minutes") or 0),
  }

  -- No callback: this is a daemon, and waiting on it would hold a slot until it
  -- exits. Its readiness is observed through the lock file instead.
  M.forgetEndpoint()
  return noctalia.runAsync(argv)
end

-- ── HTTP ────────────────────────────────────────────────────────────────────

local function call(method: string, path: string, body: any, onDone)
  local endpoint = M.endpoint()
  if endpoint == nil then
    if onDone then onDone(nil, "no_bridge") end
    return false
  end
  local request = {
    url = "http://127.0.0.1:" .. tostring(endpoint.port) .. path,
    method = method,
    headers = { "X-Bridge-Token: " .. endpoint.token, "Content-Type: application/json" },
  }
  if body ~= nil then
    local encoded = noctalia.json.encode(body)
    request.body = encoded or "{}"
  end
  return noctalia.http(request, function(response)
    if not response.ok or response.status >= 400 then
      -- A dead socket and a stale lock look identical from here; drop the cache
      -- so the next call re-reads it (or fails cleanly if it is gone).
      if not response.ok then M.forgetEndpoint() end
      if onDone then onDone(nil, "http_" .. tostring(response.status)) end
      return
    end
    local decoded = noctalia.json.decode(response.body)
    if onDone then onDone(decoded, nil) end
  end)
end

function M.get(path, onDone) return call("GET", path, nil, onDone) end
function M.post(path, body, onDone) return call("POST", path, body or {}, onDone) end

-- Long-lived SSE subscription. Returns the handle so the caller can stop it
-- (panels must, on close). onEvent receives the decoded object per frame.
function M.events(onEvent, onClose)
  local endpoint = M.endpoint()
  if endpoint == nil then
    return nil
  end
  return noctalia.httpStream({
    url = "http://127.0.0.1:" .. tostring(endpoint.port) .. "/events",
    method = "GET",
    headers = { "X-Bridge-Token: " .. endpoint.token },
  }, function(line)
    -- Frames are "data: {...}"; the keepalive comment starts with ':'.
    if line:sub(1, 6) ~= "data: " then
      return
    end
    local decoded = noctalia.json.decode(line:sub(7))
    if type(decoded) == "table" then
      onEvent(decoded)
    end
  end, function(result)
    M.forgetEndpoint()
    if onClose then onClose(result) end
  end)
end

-- ── Formatting ──────────────────────────────────────────────────────────────

function M.percent(value: number?): string
  if type(value) ~= "number" then
    return "--"
  end
  return string.format("%d%%", math.floor(value + 0.5))
end

-- "3h 20m" / "12m" / "now". Used for rate-limit resets, where minute precision
-- is the most anyone acts on.
function M.until_(unixSeconds: number?): string
  if type(unixSeconds) ~= "number" or unixSeconds <= 0 then
    return "--"
  end
  local remaining = unixSeconds - os.time()
  if remaining <= 0 then
    return noctalia.tr("time.now")
  end
  local hours = math.floor(remaining / 3600)
  local minutes = math.floor((remaining % 3600) / 60)
  if hours > 0 then
    return string.format("%dh %dm", hours, minutes)
  end
  if minutes > 0 then
    return string.format("%dm", minutes)
  end
  return noctalia.tr("time.soon")
end

function M.duration(ms: number?): string
  if type(ms) ~= "number" or ms <= 0 then
    return ""
  end
  if ms < 1000 then
    return string.format("%dms", math.floor(ms))
  end
  if ms < 60000 then
    return string.format("%.1fs", ms / 1000)
  end
  return string.format("%dm %ds", math.floor(ms / 60000), math.floor((ms % 60000) / 1000))
end

function M.cost(usd: number?): string
  if type(usd) ~= "number" or usd <= 0 then
    return ""
  end
  if usd < 0.01 then
    return "<$0.01"
  end
  return string.format("$%.2f", usd)
end

function M.tokens(count: number?): string
  if type(count) ~= "number" or count <= 0 then
    return "0"
  end
  if count >= 1000000 then
    return string.format("%.1fM", count / 1000000)
  end
  if count >= 1000 then
    return string.format("%.1fk", count / 1000)
  end
  return tostring(math.floor(count))
end

-- ISO-8601 with a timezone offset, as the usage endpoint returns it, to epoch
-- seconds. os.time normalizes the struct, so the offset is applied by hand.
function M.parseIso(text: string?): number
  if type(text) ~= "string" or text == "" then
    return 0
  end
  local y, mo, d, h, mi, s = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if y == nil then
    return 0
  end
  local stamp = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    isdst = false,
  })
  -- os.time read those fields as local time; correct back to UTC, then apply the
  -- string's own offset.
  local utc = os.time(os.date("!*t", stamp))
  stamp = stamp + (stamp - utc)
  local sign, oh, om = text:match("([%+%-])(%d%d):(%d%d)$")
  if sign then
    local shift = tonumber(oh) * 3600 + tonumber(om) * 60
    stamp = stamp + (sign == "+" and -shift or shift)
  end
  return stamp
end

function M.severity(percent: number?): string
  if type(percent) ~= "number" then
    return "normal"
  end
  if percent >= 90 then
    return "critical"
  end
  if percent >= 75 then
    return "warning"
  end
  return "normal"
end

-- Palette role for a usage severity. Roles, never hex: the shell re-resolves
-- them against the active scheme, including light mode.
function M.severityColor(severity: string): string
  if severity == "critical" then
    return "error"
  end
  if severity == "warning" then
    return "tertiary"
  end
  return "on_surface"
end

-- Permission-mode values are camelCase on the wire ("acceptEdits"), but catalog
-- translation keys may only use lowercase segments, so the two are mapped rather
-- than concatenated. An unknown mode shows its raw name instead of a wrong label.
local MODE_KEYS = {
  default = "default",
  plan = "plan",
  acceptEdits = "accept_edits",
  auto = "auto",
  manual = "manual",
  dontAsk = "dont_ask",
  bypassPermissions = "bypass_permissions",
}

function M.modeLabel(mode: string?): string
  local key = MODE_KEYS[tostring(mode or "")]
  if key == nil then
    return tostring(mode or "")
  end
  return noctalia.tr("mode." .. key)
end

function M.modeHint(mode: string?): string
  local key = MODE_KEYS[tostring(mode or "")]
  if key == nil then
    return ""
  end
  return noctalia.tr("mode_hint." .. key)
end

-- Accent for a tool row, by what the call can reach.
function M.riskColor(risk: string): string
  if risk == "exec" then
    return "error"
  end
  if risk == "write" then
    return "tertiary"
  end
  if risk == "network" or risk == "mcp" then
    return "secondary"
  end
  return "on_surface_variant"
end

function M.riskGlyph(name: string, risk: string): string
  if name == "Bash" then return "terminal-2" end
  if name == "Read" then return "file-text" end
  if name == "Write" then return "file-plus" end
  if name == "Edit" then return "file-pencil" end
  if name == "Glob" then return "files" end
  if name == "Grep" then return "search" end
  if name == "WebFetch" or name == "WebSearch" then return "world-search" end
  if name == "Task" then return "subtask" end
  if name == "TodoWrite" then return "checklist" end
  if risk == "mcp" then return "plug" end
  return "tool"
end

return M
