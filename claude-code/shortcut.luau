--!nonstrict
-- Claude Code control-center tile: turn status at a glance, one click to the
-- console. Interrupting from here goes through the same service IPC as the
-- bar pill's middle click, so both entries agree on how a turn gets stopped.

local shared = require("./shared.luau")

local status = noctalia.state.get("status")

local function phaseOf(st)
  if type(st) == "table" and type(st.phase) == "string" and st.phase ~= "" then
    return st.phase
  end
  return "off"
end

local function render()
  local phase = phaseOf(status)
  local active = phase == "busy" or phase == "awaiting"

  -- Off just reads as the plugin's name; anything else is worth a live word.
  local label = phase == "off" and noctalia.tr("title") or noctalia.tr(`status.{phase}`)

  shortcut.setLabel(label)
  shortcut.setIcon("player-play", "sparkles")
  shortcut.setActive(active)
  shortcut.setEnabled(true)
end

render()

noctalia.state.watch("status", function(value)
  status = value
  render()
end)

function onClick()
  noctalia.togglePanel(shared.PANEL)
end

function onRightClick()
  noctalia.runAsync({ "noctalia", "msg", "plugin", shared.PLUGIN_ID .. ":service", "all", "interrupt" })
end
