--!nonstrict
-- Headless owner of everything that must outlive the console panel: the
-- subscription usage poll, the bridge's status mirror, and the notification that
-- a turn finished while you were looking elsewhere.
--
-- Usage is fetched here in Luau rather than through the sidecar on purpose. The
-- bar pill is the part of this plugin people leave running all day, and doing it
-- this way means a user who never opens the console never pays for a background
-- process — no python, no curl, no jq. The sidecar starts on first use and not
-- before.

local shared = require("./shared.luau")

local CREDENTIALS = "~/.claude/.credentials.json"
local USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

local TICK_MS = 30000

local lastUsageAt = 0
local usageInFlight = false
local usageStartedAt = 0
local stream = nil
local streamRetryAt = 0
local lastPhase = "off"

-- ── Usage ───────────────────────────────────────────────────────────────────

local function publishUsage(value)
  noctalia.state.set("usage", value)
end

-- The endpoint Claude Code itself reads. The token is the one the CLI already
-- holds; it is never refreshed here, because rotating it would invalidate the
-- CLI's own copy — an expired token is reported as a re-auth prompt instead.
local function fetchUsage()
  -- A request that never calls back would otherwise latch the flag and stop the
  -- pill updating for the rest of the session.
  if usageInFlight and os.time() - usageStartedAt < 60 then
    return
  end
  local raw = noctalia.readFile(CREDENTIALS)
  if raw == nil or raw == "" then
    publishUsage({ ok = false, error = "no_credentials" })
    return
  end
  local decoded = noctalia.json.decode(raw)
  local oauth = type(decoded) == "table" and decoded.claudeAiOauth or nil
  local token = type(oauth) == "table" and oauth.accessToken or nil
  if type(token) ~= "string" or token == "" then
    publishUsage({ ok = false, error = "no_credentials" })
    return
  end

  usageInFlight = true
  usageStartedAt = os.time()
  local started = noctalia.http({
    url = USAGE_URL,
    method = "GET",
    headers = {
      "Authorization: Bearer " .. token,
      "Accept: application/json",
      "Content-Type: application/json",
      -- Identifies the caller as Claude Code; the endpoint is gated on it.
      "User-Agent: claude-code/2.1.241",
      "anthropic-beta: oauth-2025-04-20",
    },
  }, function(response)
    usageInFlight = false
    lastUsageAt = os.time()
    if not response.ok or response.status ~= 200 then
      publishUsage({ ok = false, error = "http_" .. tostring(response.status) })
      return
    end
    local body = noctalia.json.decode(response.body)
    if type(body) ~= "table" then
      publishUsage({ ok = false, error = "bad_response" })
      return
    end

    local five = type(body.five_hour) == "table" and body.five_hour or {}
    local seven = type(body.seven_day) == "table" and body.seven_day or {}
    local sessionPercent = tonumber(five.utilization) or 0
    local weeklyPercent = tonumber(seven.utilization) or 0
    local maxPercent = math.max(sessionPercent, weeklyPercent)

    -- The flat `limits` array is the canonical list and is the only place a
    -- model-scoped window (a plan's Opus-only week, say) shows up at all.
    local windows = {}
    if type(body.limits) == "table" then
      for _, entry in ipairs(body.limits) do
        if type(entry) == "table" then
          local scope = type(entry.scope) == "table" and entry.scope or nil
          local model = scope and type(scope.model) == "table" and scope.model.display_name or ""
          windows[#windows + 1] = {
            kind = tostring(entry.kind or ""),
            group = tostring(entry.group or ""),
            model = tostring(model or ""),
            percent = tonumber(entry.percent) or 0,
            severity = tostring(entry.severity or "normal"),
            resets_at = shared.parseIso(entry.resets_at),
            active = entry.is_active == true,
          }
        end
      end
    end

    local extra = type(body.extra_usage) == "table" and body.extra_usage or {}

    publishUsage({
      ok = true,
      session_percent = sessionPercent,
      weekly_percent = weeklyPercent,
      max_percent = maxPercent,
      session_resets_at = shared.parseIso(five.resets_at),
      weekly_resets_at = shared.parseIso(seven.resets_at),
      severity = shared.severity(maxPercent),
      windows = windows,
      extra_enabled = extra.is_enabled == true,
      fetched_at = lastUsageAt,
    })
  end)

  if not started then
    usageInFlight = false
    publishUsage({ ok = false, error = "offline" })
  end
end

-- ── Bridge status mirror ────────────────────────────────────────────────────

local function publishStatus(status)
  noctalia.state.set("status", status)

  local phase = tostring(status.phase or "off")
  if phase ~= lastPhase then
    if noctalia.getConfig("notify_on_idle") ~= false
      and noctalia.state.get("panel_open") ~= true then
      if phase == "awaiting" then
        noctalia.notify(noctalia.tr("notify.permission.title"), noctalia.tr("notify.permission.body"))
      elseif phase == "idle" and lastPhase == "busy" then
        noctalia.notify(noctalia.tr("notify.done.title"), noctalia.tr("notify.done.body"))
      elseif phase == "error" then
        noctalia.notifyError(noctalia.tr("notify.error.title"), tostring(status.error or ""))
      end
    end
    lastPhase = phase
  end
end

local function stopStream()
  if stream ~= nil then
    stream.stop()
    stream = nil
  end
end

-- Only ever attaches to a bridge that is already running: the service does not
-- start one, so an idle bar costs nothing.
local function attachStream()
  if stream ~= nil or shared.endpoint() == nil then
    return
  end
  stream = shared.events(function(event)
    local kind = event.e
    if kind == "hello" then
      local snapshot = event.snapshot
      if type(snapshot) == "table" and type(snapshot.status) == "table" then
        publishStatus(snapshot.status)
      end
    elseif kind == "status" and type(event.status) == "table" then
      publishStatus(event.status)
    end
  end, function()
    stream = nil
    -- Backoff so a bridge that is down does not get hammered every tick.
    streamRetryAt = os.time() + 20
    publishStatus({ phase = "off" })
  end)
end

-- ── Entry points ────────────────────────────────────────────────────────────

function update()
  local interval = tonumber(noctalia.getConfig("usage_refresh_minutes")) or 5
  if interval < 1 then
    interval = 1
  end
  if os.time() - lastUsageAt >= interval * 60 then
    fetchUsage()
  end

  if stream == nil and os.time() >= streamRetryAt then
    attachStream()
  end
end

function onIpc(event: string, payload: string?)
  if event == "refresh" then
    lastUsageAt = 0
    fetchUsage()
  elseif event == "interrupt" then
    shared.post("/control", { subtype = "interrupt" })
  elseif event == "start" then
    shared.launch()
    streamRetryAt = 0
  elseif event == "stop" then
    shared.post("/session", { action = "stop" })
  elseif event == "shutdown" then
    stopStream()
    shared.post("/shutdown", {})
  end
end

function onConfigChanged()
  -- Push the shell-side settings the sidecar cares about, if one is running.
  shared.post("/session", {
    action = "options",
    options = {
      binary = noctalia.getConfig("binary"),
      permission_prompts = noctalia.getConfig("permission_prompts"),
      permission_timeout = noctalia.getConfig("permission_timeout"),
      idle_shutdown_minutes = noctalia.getConfig("idle_shutdown_minutes"),
    },
  })
  lastUsageAt = 0
  fetchUsage()
end

function onEnable()
  noctalia.setUpdateInterval(TICK_MS)
  fetchUsage()
  attachStream()
end

function onExit(signal: number, reason: string)
  stopStream()
  -- Leave the session running across a plugin reload — that is the whole point
  -- of it being a separate process — but never leak it past a disable.
  if reason == "disable" or reason == "uninstall" then
    shared.post("/shutdown", {})
  end
end

noctalia.setUpdateInterval(TICK_MS)
publishStatus({ phase = "off" })
fetchUsage()
attachStream()
