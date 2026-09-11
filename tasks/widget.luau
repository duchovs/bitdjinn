--!nonstrict
-- Bar widget: a live count of what is outstanding, and the panel toggle.
--
-- It reads the cache the service writes and never makes a request of its own,
-- so several bars on several outputs cost nothing extra.

local store = require("./lib/store.luau")

local PANEL_ID = "duchovs/tasks:panel"

local counts = { open = 0, due = 0, overdue = 0 }
local syncing = false
local lastError = ""

local function countMode(): string
  local mode = noctalia.getConfig("count_mode")
  return type(mode) == "string" and mode or "due"
end

local function displayCount(): number
  local mode = countMode()
  if mode == "open" then
    return counts.open
  elseif mode == "overdue" then
    return counts.overdue
  end
  return counts.due
end

local function refreshTooltip()
  local rows = {
    { key = noctalia.tr("tooltip.open"), value = tostring(counts.open) },
    { key = noctalia.tr("tooltip.due_today"), value = tostring(counts.due) },
    { key = noctalia.tr("tooltip.overdue"), value = tostring(counts.overdue) },
  }
  if lastError ~= "" then
    table.insert(rows, { key = noctalia.tr("tooltip.status"), value = store.errorText(lastError) })
  elseif syncing then
    table.insert(rows, { key = noctalia.tr("tooltip.status"), value = noctalia.tr("tooltip.syncing") })
  end
  barWidget.setTooltip(rows)
end

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "checklist")
  if countMode() == "none" then
    barWidget.setText("")
  else
    barWidget.setText(tostring(displayCount()))
  end
  -- The glyph carries the state so a glance is enough: red when something is
  -- late, the accent when work is due today, muted when the list is clear.
  if lastError ~= "" then
    barWidget.setGlyphColor("error")
  elseif counts.overdue > 0 then
    barWidget.setGlyphColor("error")
  elseif counts.due > 0 then
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyphColor("on_surface")
  end
  refreshTooltip()
end

local function reload()
  local cache = store.loadCache()
  counts = store.counts(cache.tasks, store.startOfToday())
  render()
end

reload()

noctalia.state.watch(store.CACHE_REV, function(_value)
  reload()
end)

noctalia.state.watch(store.STATUS, function(value)
  if type(value) ~= "table" then
    return
  end
  syncing = value.syncing == true
  lastError = type(value.error) == "string" and value.error or ""
  render()
end)

-- The day boundary moves under a long-running shell, so an overdue count that
-- was right at 23:59 is wrong at 00:01. Re-derive it once a minute.
noctalia.setUpdateInterval(60 * 1000)

function update()
  reload()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.state.set(store.SYNC_REQUEST, noctalia.nowMs())
end
