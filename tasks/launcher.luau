--!nonstrict
-- Launcher provider (`/td`): search every list, tick something off, or capture
-- a new task without opening the panel.
--
-- Reads come from the cache the service maintains, so typing is never gated on
-- the network. Only the write on activation goes to the server.

local caldav = require("./lib/caldav.luau")
local ical = require("./lib/ical.luau")
local store = require("./lib/store.luau")

local PANEL_ID = "duchovs/tasks:panel"
local MAX_RESULTS = 25

local accounts = {}

local function refreshAccounts()
  store.resolveAccounts(function(resolved, _problems)
    accounts = resolved
  end)
end

refreshAccounts()

local function findAccount(accountId: string)
  for _, account in ipairs(accounts) do
    if account.id == accountId then
      return account
    end
  end
  return nil
end

local function listsById()
  local byId = {}
  for _, list in ipairs(store.loadCache().lists) do
    byId[list.id] = list
  end
  return byId
end

local function subtitleFor(task, lists, today: number): string
  local parts = {}
  local list = lists[task.listId]
  if list ~= nil then
    table.insert(parts, list.name)
  end
  local bucket = store.dueBucket(task, today)
  if bucket == "overdue" then
    table.insert(parts, noctalia.tr("section.overdue"))
  elseif bucket == "today" then
    table.insert(parts, noctalia.tr("due.today"))
  elseif bucket == "tomorrow" then
    table.insert(parts, noctalia.tr("due.tomorrow"))
  elseif task.due ~= nil then
    table.insert(parts, noctalia.formatTime("%b %d", task.due.epoch))
  end
  return table.concat(parts, "  ·  ")
end

function onQuery(text)
  local query = noctalia.string.trim(text or "")
  local cache = store.loadCache()
  local lists = listsById()
  local today = store.startOfToday()
  local results = {}

  if query ~= "" then
    -- Capture first: the whole point of `/td buy milk` is that it does not
    -- make you pick it out of a list of near-matches.
    table.insert(results, {
      id = "add|" .. query,
      title = noctalia.tr("launcher.add", { summary = query }),
      subtitle = noctalia.tr("launcher.add_subtitle"),
      glyph = "plus",
      score = 10000,
    })
  end

  local matches = {}
  for _, task in ipairs(cache.tasks) do
    if not task.completed and not task.cancelled then
      local score = nil
      if query == "" then
        -- No query: soonest-due first, so the list is a genuine agenda.
        score = task.due ~= nil and (5000 - math.floor((task.due.epoch - today) / store.DAY)) or 0
      else
        score = noctalia.fuzzyScore(query, task.summary)
      end
      if score ~= nil then
        table.insert(matches, { task = task, score = score })
      end
    end
  end
  table.sort(matches, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.task.summary:lower() < b.task.summary:lower()
  end)

  for index, match in ipairs(matches) do
    if index > MAX_RESULTS then
      break
    end
    table.insert(results, {
      id = "task|" .. match.task.uid,
      title = match.task.summary ~= "" and match.task.summary or noctalia.tr("untitled"),
      subtitle = subtitleFor(match.task, lists, today),
      glyph = match.task.important and "flag" or "square",
      score = match.score,
    })
  end

  table.insert(results, {
    id = "panel",
    title = noctalia.tr("launcher.open_panel"),
    subtitle = noctalia.trp("launcher.open_panel_subtitle", #cache.lists, { count = #cache.lists }),
    glyph = "checklist",
    score = -1,
  })

  launcher.setResults(text, results)
end

local function completeTask(uid: string)
  local cache = store.loadCache()
  for index, task in ipairs(cache.tasks) do
    if task.uid == uid then
      local account = findAccount(task.listId:match("^([^|]+)|") or "")
      if account == nil then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.no_account"))
        return
      end
      local calendar = ical.parse(task.ics)
      local vtodo = calendar ~= nil and ical.findComponent(calendar, "VTODO") or nil
      if vtodo == nil then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.bad_task"))
        return
      end
      ical.markComplete(vtodo, true, os.time())
      local ics = ical.serialize(calendar)

      -- Update the cache before the request so the bar count and an open panel
      -- both react at once; the service repairs it if the write fails.
      task.completed = true
      task.status = "COMPLETED"
      task.ics = ics
      cache.tasks[index] = task
      store.saveCache(cache)

      caldav.putTask(account, task.href, ics, task.etag, function(_etag, err)
        if err ~= nil then
          noctalia.notifyError(noctalia.tr("title"), store.errorText(err))
        else
          noctalia.notify(noctalia.tr("title"), noctalia.tr("launcher.completed", { summary = task.summary }))
        end
        noctalia.state.set(store.SYNC_REQUEST, noctalia.nowMs())
      end)
      return
    end
  end
end

local function addTask(summary: string)
  summary = noctalia.string.trim(summary)
  if summary == "" then
    return
  end
  local cache = store.loadCache()
  local prefs = store.loadPrefs()

  local target = nil
  for _, list in ipairs(cache.lists) do
    if not list.readOnly then
      if list.id == prefs.quickAddList or list.id == prefs.selectedList then
        target = list
        break
      end
      if target == nil then
        target = list -- first writable list, unless a preferred one turns up
      end
    end
  end
  if target == nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.no_writable_list"))
    return
  end
  local account = findAccount(target.accountId)
  if account == nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.no_account"))
    return
  end

  local now = os.time()
  local uid = caldav.newUid()
  local calendar = ical.newTodo(uid, summary, now, nil)
  local ics = ical.serialize(calendar)
  local href = caldav.taskHref(target, uid)

  table.insert(cache.tasks, {
    uid = uid,
    href = href,
    etag = "",
    listId = target.id,
    summary = summary,
    description = "",
    status = "NEEDS-ACTION",
    completed = false,
    cancelled = false,
    priority = 0,
    important = false,
    recurring = false,
    ics = ics,
  })
  store.saveCache(cache)

  caldav.putTask(account, href, ics, nil, function(_etag, err)
    if err ~= nil then
      noctalia.notifyError(noctalia.tr("title"), store.errorText(err))
    else
      noctalia.notify(
        noctalia.tr("title"),
        noctalia.tr("launcher.added", { summary = summary, list = target.name })
      )
    end
    noctalia.state.set(store.SYNC_REQUEST, noctalia.nowMs())
  end)
end

function onActivate(id)
  if id == "panel" then
    return noctalia.togglePanel(PANEL_ID)
  end
  local kind, payload = id:match("^([^|]+)|(.*)$")
  if kind == "add" then
    addTask(payload)
  elseif kind == "task" then
    completeTask(payload)
  end
end

function onConfigChanged()
  refreshAccounts()
end
