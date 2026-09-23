-- Probes whether GuiBeginScrollContainer actually renders its contents.
--
-- The panel's Log tab uses one, and it showed nothing. Two very different causes are
-- possible: the scroll container does not work as documented in this build, or our use
-- of it is wrong. This tells them apart by drawing known text inside a container and
-- known text outside it in the same frame, then reporting what appeared.
--
-- It also reports GuiGetScreenDimensions and whether the widgets land where expected,
-- because a container that renders at the wrong offset looks identical to one that
-- renders nothing.

local fixture = {}

local gui = nil
local frames = 0

function fixture.run(params)
  params = params or {}
  if type(GuiCreate) ~= "function" then
    return { ok = false, error = "no Gui API in this sandbox" }
  end
  if not gui then gui = GuiCreate() end

  local out = { ok = true }
  local w, h = GuiGetScreenDimensions(gui)
  out.screen = { w = w, h = h }

  GuiStartFrame(gui)

  -- A: plain text, known position
  GuiColorSetForNextWidget(gui, 1, 0, 0, 1)
  GuiText(gui, 40, 40, "PROBE-PLAIN-TEXT")

  -- B: text inside a scroll container, positioned well away from A
  GuiColorSetForNextWidget(gui, 0, 1, 0, 1)
  GuiBeginScrollContainer(gui, 991, 40, 300, 200)
  GuiText(gui, 0, 0, "PROBE-INSIDE-SCROLL-1")
  GuiText(gui, 0, 14, "PROBE-INSIDE-SCROLL-2")
  GuiText(gui, 0, 28, "PROBE-INSIDE-SCROLL-3")
  GuiEndScrollContainer(gui)

  -- C: text after the container, to prove the frame keeps running past it
  GuiColorSetForNextWidget(gui, 0.4, 0.6, 1, 1)
  GuiText(gui, 40, 300, "PROBE-AFTER-SCROLL")

  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)

  frames = frames + 1
  out.frame = frames
  out.drawn = {
    "PROBE-PLAIN-TEXT at (40,40)",
    "PROBE-INSIDE-SCROLL-1..3 inside container at (40,40) 300x200",
    "PROBE-AFTER-SCROLL at (40,300)",
  }
  out.note = "If the three INSIDE lines do not appear on screen, the scroll container " ..
             "is not usable in this build and the panel must not rely on it."
  return out
end

function fixture.stop()
  gui = nil
  frames = 0
  return { ok = true }
end

return fixture
