-- glint demo cart — palette marquee
--
-- A 4-KB existence proof: the smallest cart that exercises every leg
-- of the engine loop without leaning on an asset bundle.
--
--   _init  — one-time setup; tick counter starts at 0
--   _update — runs at 60 Hz; advances the tick
--   _draw   — runs every frame; cycles backdrop, places a sine-curve dot
--
-- Cart-author API surface used here (see doc/dx-reliability-spec.md):
--   cls(c)          fill framebuffer with palette index c
--   pset(x, y, c)   set a single pixel; out-of-bounds is silently dropped
--   sin(t)          turn-based sin (full cycle = 1.0); deterministic LUT
--
-- This cart will run as soon as the Luau VM lands (W5). Until then it
-- exists as a parser target for `glint pack` and as documentation of
-- what a "hello world" cart looks like.

function _init()
  t = 0
end

function _update()
  t = t + 1
end

function _draw()
  -- backdrop cycles through the 16-color palette every ~8 seconds at 60 Hz
  cls(flr(t / 30) % 16)

  -- sparkbright dot traces a sine curve across the screen
  local x = t % 128
  local y = 64 + 32 * sin(t / 120)
  pset(x, y, 11)
end
