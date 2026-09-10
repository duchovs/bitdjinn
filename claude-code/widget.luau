--!nonstrict
-- Claude Code bar pill: the "status"/"usage" snapshot service.luau publishes,
-- boiled down to one glyph + one short label. Never touches the bridge
-- directly, so it stays cheap even while the console (and the sidecar under
-- it) is closed.

local shared = require("./shared.luau")

local status = noctalia.state.get("status")
local usage = noctalia.state.get("usage")

local PHASE_GLYPHS = {
  off = "plug-off",
  starting = "loader",
  idle = "sparkles",
  busy = "player-play",
  awaiting = "alert-triangle",
  error = "alert-circle",
}

local function phaseOf(st)
  if type(st) == "table" and type(st.phase) == "string" and st.phase ~= "" then
    return st.phase
  end
  return "off"
end

local function isTurnLive(phase)
  return phase == "busy" or phase == "awaiting"
end

-- Phase wins over usage severity: a pending permission answer or a hard error
-- is more urgent than "your quota is at 80%".
local function pillColor(phase)
  if phase == "awaiting" or phase == "error" then
    return "error"
  end
  if phase == "busy" then
    return "primary"
  end
  if type(usage) == "table" and usage.ok == true then
    return shared.severityColor(tostring(usage.severity or "normal"))
  end
  return "on_surface"
end

local function usagePercent(window)
  if type(usage) ~= "table" or usage.ok ~= true then
    return nil
  end
  if window == "weekly" then
    return usage.weekly_percent
  end
  if window == "max" then
    return usage.max_percent
  end
  return usage.session_percent
end

local function orUnknown(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return noctalia.tr("tooltip.unknown")
end

local function buildTooltip()
  local st = type(status) == "table" and status or {}
  local rows = {
    { key = noctalia.tr("tooltip.plan"), value = orUnknown(st.plan) },
    { key = noctalia.tr("tooltip.mode"), value = orUnknown(shared.modeLabel(st.mode)) },
    { key = noctalia.tr("tooltip.model"), value = orUnknown(st.model) },
  }

  if type(usage) == "table" and usage.ok == true then
    table.insert(rows, {
      key = noctalia.tr("tooltip.session"),
      value = `{shared.percent(usage.session_percent)} · {shared.until_(usage.session_resets_at)}`,
    })
    table.insert(rows, {
      key = noctalia.tr("tooltip.weekly"),
      value = `{shared.percent(usage.weekly_percent)} · {shared.until_(usage.weekly_resets_at)}`,
    })
  else
    local detail = noctalia.tr("tooltip.usage_unavailable")
    if type(usage) == "table" and type(usage.error) == "string" and usage.error ~= "" then
      detail = usage.error
    end
    table.insert(rows, { key = noctalia.tr("tooltip.usage"), value = detail })
  end

  table.insert(rows, { key = noctalia.tr("tooltip.cwd"), value = orUnknown(st.cwd) })

  if st.phase == "error" and type(st.error) == "string" and st.error ~= "" then
    table.insert(rows, { key = noctalia.tr("tooltip.error"), value = st.error })
  end

  return rows
end

local function render()
  local phase = phaseOf(status)
  local color = pillColor(phase)
  local glyphName = PHASE_GLYPHS[phase] or PHASE_GLYPHS.off

  local content = noctalia.getConfig("pill_content")
  if content ~= "status" and content ~= "usage" and content ~= "glyph" then
    content = "auto"
  end
  local mode = content
  if content == "auto" then
    -- A running turn or a pending permission answer is worth naming; anything
    -- else is better spent as the number people actually watch the pill for.
    mode = isTurnLive(phase) and "status" or "usage"
  end

  local showGlyph = noctalia.getConfig("show_glyph")
  if showGlyph == nil then
    showGlyph = true
  end

  local children = {}
  if content == "glyph" then
    -- The whole point of this mode is the icon; show it even with show_glyph off.
    table.insert(children, ui.glyph({ name = glyphName, color = color }))
  else
    if showGlyph then
      table.insert(children, ui.glyph({ name = glyphName, color = color }))
    end
    if mode == "status" then
      table.insert(children, ui.label({ text = noctalia.tr(`status.{phase}`), color = color }))
    else
      local window = noctalia.getConfig("usage_window")
      if window ~= "weekly" and window ~= "max" then
        window = "session"
      end
      table.insert(children, ui.label({ text = shared.percent(usagePercent(window)), color = color }))
    end
  end

  barWidget.render(ui.row({ gap = 4, align = "center" }, children))
  barWidget.setTooltip(buildTooltip())
end

noctalia.state.watch("status", function(value)
  status = value
  render()
end)

noctalia.state.watch("usage", function(value)
  usage = value
  render()
end)

-- The state watches above cover every real change; this tick only exists to
-- keep the tooltip's "resets in" countdown honest between them.
function update()
  render()
end

function onMiddleClick()
  -- Middle click is unbound in the manifest specifically for this: interrupt
  -- the running turn without opening the console.
  noctalia.runAsync({ "noctalia", "msg", "plugin", shared.PLUGIN_ID .. ":service", "all", "interrupt" })
end

-- Once, not per tick: the tooltip's reset countdown is the only thing that goes
-- stale without a state change, and half a minute is finer than it displays.
noctalia.setUpdateInterval(30000)
render()
