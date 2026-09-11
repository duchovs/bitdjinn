--!nonstrict
-- Shared state: account resolution, on-disk cache, view preferences, and the
-- task-shaping helpers every entry needs.
--
-- Plugin entries run in isolated VMs, so nothing here is shared in memory.
-- The service owns the network and writes `cache.json`; the panel, widget, and
-- launcher read it. `noctalia.state` carries only small signals -- a revision
-- counter and a status record -- because it is in-memory and cleared when the
-- plugin stops, while the cache has to survive a restart so the bar count is
-- right before the first sync of a session completes.

local M = {}

-- ── State channel keys ───────────────────────────────────────────────────────

M.CACHE_REV = "cache_rev" -- bumped by whoever rewrites cache.json
M.STATUS = "status" -- { syncing, error, lastSyncAt }
M.SYNC_REQUEST = "sync_request" -- bumped to ask the service for an immediate sync
M.PREFS_REV = "prefs_rev" -- bumped when view preferences change

-- Nextcloud Login Flow v2 is driven by the service, not the panel: approving in
-- the browser means clicking outside the panel, which dismisses it, and the
-- flow's poll endpoint returns its credentials exactly once. A panel-owned poll
-- would therefore be gone at the moment the answer arrives.
M.LOGIN_REQUEST = "login_request" -- { url, at } from the panel
M.LOGIN_CANCEL = "login_cancel" -- bumped by the panel to abandon a flow
M.LOGIN_STATE = "login_state" -- { phase, login, message, at } from the service

-- ── Paths ────────────────────────────────────────────────────────────────────

local dataDirCache = nil

function M.dataDir(): string?
  if dataDirCache == nil then
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
      noctalia.log("tasks: no plugin data directory: " .. tostring(err))
      return nil
    end
    dataDirCache = dir
  end
  return dataDirCache
end

local function pathFor(name: string): string?
  local dir = M.dataDir()
  return dir ~= nil and (dir .. "/" .. name) or nil
end

local function readJson(name: string)
  local path = pathFor(name)
  if path == nil then
    return nil
  end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then
    return nil
  end
  local decoded = noctalia.json.decode(raw)
  return type(decoded) == "table" and decoded or nil
end

local function writeJson(name: string, value): boolean
  local path = pathFor(name)
  if path == nil then
    return false
  end
  local encoded = noctalia.json.encode(value)
  if encoded == nil then
    return false
  end
  -- Write to a sibling and rename, so a reader never sees a half-written file:
  -- the service can be rewriting the cache exactly while the panel reads it.
  local temp = path .. ".tmp"
  local ok, err = noctalia.writeFile(temp, encoded)
  if not ok then
    noctalia.log("tasks: could not write " .. name .. ": " .. tostring(err))
    return false
  end
  local renamed, renameErr = noctalia.renameFile(temp, path)
  if not renamed then
    noctalia.log("tasks: could not replace " .. name .. ": " .. tostring(renameErr))
    return false
  end
  return true
end

M.readJson = readJson
M.writeJson = writeJson

-- ── Credentials ──────────────────────────────────────────────────────────────
--
-- The Nextcloud app password from Login Flow v2 has to be kept somewhere; it
-- lands in the plugin data directory with 0600 permissions rather than in the
-- shell config, which is world-readable in a typical setup. Anyone who prefers
-- a real secret store points `nextcloud_password_command` at it instead, and
-- nothing is written here at all.

local CREDENTIALS = "credentials.json"

function M.loadCredentials()
  return readJson(CREDENTIALS) or {}
end

function M.saveCredentials(credentials): boolean
  if not writeJson(CREDENTIALS, credentials) then
    return false
  end
  local path = pathFor(CREDENTIALS)
  if path ~= nil then
    noctalia.runAsync({ "chmod", "600", path })
  end
  return true
end

function M.clearCredentials()
  local path = pathFor(CREDENTIALS)
  if path ~= nil and noctalia.fileExists(path) then
    noctalia.removeFile(path)
  end
end

-- Runs a password command and hands its first output line to `onDone`, or nil.
-- The first line only: `pass show` prints the password first and metadata after.
local function runPasswordCommand(command: string, onDone)
  local accepted = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("tasks: password command failed: " .. noctalia.string.trim(result.stderr or ""))
      return onDone(nil)
    end
    local first = (result.stdout or ""):match("^[^\r\n]*") or ""
    first = noctalia.string.trim(first)
    onDone(first ~= "" and first or nil)
  end, 15000)
  if not accepted then
    onDone(nil)
  end
end

-- ── Accounts ─────────────────────────────────────────────────────────────────
--
-- `onDone(accounts, problems)`. An account that is enabled but not yet usable
-- (no password, no server URL) is reported in `problems` rather than silently
-- skipped, so the panel can say what is missing instead of showing an empty
-- list that looks like a sync failure.

function M.resolveAccounts(onDone)
  local accounts = {}
  local problems = {}
  local credentials = M.loadCredentials()

  local function finish()
    table.sort(accounts, function(a, b)
      return a.id < b.id
    end)
    onDone(accounts, problems)
  end

  local function resolveNextcloud()
    if noctalia.getConfig("nextcloud_enabled") ~= true then
      return finish()
    end
    local caldav = require("./caldav.luau")
    local stored = credentials.nextcloud or {}
    local url = noctalia.string.trim(noctalia.getConfig("nextcloud_url") or "")
    if url == "" then
      url = stored.server or ""
    end
    if url == "" then
      table.insert(problems, { kind = "nextcloud", message = "no_server" })
      return finish()
    end
    local command = noctalia.string.trim(noctalia.getConfig("nextcloud_password_command") or "")

    local function withPassword(password: string?, username: string?)
      if password == nil or password == "" or username == nil or username == "" then
        table.insert(problems, { kind = "nextcloud", message = "not_connected" })
        return finish()
      end
      table.insert(accounts, {
        id = "nextcloud",
        kind = "nextcloud",
        label = url:gsub("^https?://", ""),
        root = caldav.nextcloudRoot(url),
        username = username,
        password = password,
      })
      finish()
    end

    if command ~= "" then
      runPasswordCommand(command, function(password)
        withPassword(password, stored.username)
      end)
    else
      withPassword(stored.password, stored.username)
    end
  end

  resolveNextcloud()
end

-- ── Cache ────────────────────────────────────────────────────────────────────
--
-- { updatedAt, lists = { ... }, tasks = { ... }, errors = { ... } }
-- Tasks are stored flattened for rendering; the raw ICS of each task is kept so
-- an edit can be written back without refetching the resource first.

local CACHE = "cache.json"

function M.loadCache()
  local cache = readJson(CACHE)
  if cache == nil then
    return { updatedAt = 0, lists = {}, tasks = {}, errors = {} }
  end
  cache.lists = cache.lists or {}
  cache.tasks = cache.tasks or {}
  cache.errors = cache.errors or {}
  return cache
end

function M.saveCache(cache): boolean
  if not writeJson(CACHE, cache) then
    return false
  end
  local revision = noctalia.state.get(M.CACHE_REV)
  noctalia.state.set(M.CACHE_REV, (type(revision) == "number" and revision or 0) + 1)
  return true
end

-- ── View preferences ─────────────────────────────────────────────────────────
--
-- Plugins can read shell config but not write it, so anything the panel itself
-- toggles lives here rather than in plugin.toml settings.

local PREFS = "prefs.json"

function M.loadPrefs()
  local prefs = readJson(PREFS) or {}
  if prefs.selectedList == nil then
    prefs.selectedList = "" -- "" is the all-lists view
  end
  if prefs.showCompleted == nil then
    prefs.showCompleted = false
  end
  if prefs.sortBy == nil then
    prefs.sortBy = "due" -- "due" | "priority" | "name"
  end
  prefs.hiddenLists = prefs.hiddenLists or {}
  prefs.quickAddList = prefs.quickAddList or ""
  return prefs
end

function M.savePrefs(prefs): boolean
  if not writeJson(PREFS, prefs) then
    return false
  end
  local revision = noctalia.state.get(M.PREFS_REV)
  noctalia.state.set(M.PREFS_REV, (type(revision) == "number" and revision or 0) + 1)
  return true
end

-- Errors reach the UI as either a translation code (`no_password`) raised by
-- account resolution, or a free-form string from the protocol layer that
-- already reads as a sentence ("write returned HTTP 507"). Codes are the ones
-- worth translating; the rest passes through as written.
function M.errorText(message: string?): string
  if message == nil or message == "" then
    return ""
  end
  if message:match("^[a-z_]+$") then
    return noctalia.tr("error." .. message)
  end
  return message
end

-- ── Dates ────────────────────────────────────────────────────────────────────

function M.startOfToday(): number
  local now = os.date("*t")
  now.hour, now.min, now.sec, now.isdst = 0, 0, 0, false
  return os.time(now)
end

M.DAY = 86400

-- "overdue" | "today" | "tomorrow" | "upcoming" | "none"
function M.dueBucket(task, today: number): string
  if task.due == nil or task.due.epoch == nil then
    return "none"
  end
  local dueDay = task.due.epoch
  if dueDay < today then
    return "overdue"
  elseif dueDay < today + M.DAY then
    return "today"
  elseif dueDay < today + 2 * M.DAY then
    return "tomorrow"
  end
  return "upcoming"
end

-- A due date that has passed counts as due; an open task with no due date does
-- not. This is what the bar widget's "due" count means.
function M.counts(tasks, today: number)
  local open, due, overdue = 0, 0, 0
  for _, task in ipairs(tasks) do
    if not task.completed and not task.cancelled then
      open += 1
      local bucket = M.dueBucket(task, today)
      if bucket == "overdue" then
        overdue += 1
        due += 1
      elseif bucket == "today" then
        due += 1
      end
    end
  end
  return { open = open, due = due, overdue = overdue }
end

-- ── Sorting ──────────────────────────────────────────────────────────────────

local function compareByName(a, b): boolean
  return a.summary:lower() < b.summary:lower()
end

-- Undated tasks sink below dated ones in every mode, so a list with a handful
-- of deadlines does not bury them under an alphabetical wall of everything else.
function M.sortTasks(tasks, sortBy: string)
  table.sort(tasks, function(a, b)
    if a.completed ~= b.completed then
      return b.completed -- open work first, always
    end
    if sortBy == "priority" then
      -- PRIORITY 0 means "unset", which must sort after 9, not before 1.
      local ap = a.priority > 0 and a.priority or 10
      local bp = b.priority > 0 and b.priority or 10
      if ap ~= bp then
        return ap < bp
      end
    end
    if sortBy ~= "name" then
      local ad = a.due ~= nil and a.due.epoch or nil
      local bd = b.due ~= nil and b.due.epoch or nil
      if ad ~= bd then
        if ad == nil then
          return false
        end
        if bd == nil then
          return true
        end
        return ad < bd
      end
    end
    return compareByName(a, b)
  end)
  return tasks
end

return M
