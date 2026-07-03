--!nonstrict
-- Bar widget that opens the notes panel.

local glyph = barWidget.getConfig("glyph")

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("noctalia/notes:panel")
end

render()
