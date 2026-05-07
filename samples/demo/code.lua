function _init()
  px = 64
end
function _update()
  if btn(0) then px = px - 1 end
  if btn(1) then px = px + 1 end
end
function _draw()
  cls(0)
  pset(px, 64, 11)
end
