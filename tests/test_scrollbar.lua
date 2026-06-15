-- Regression tests for the scrollbar coordinate conversion, hover detection,
-- and drag stability.
--
-- Run with:  lua tests/test_scrollbar.lua
-- Requires:  Lua 5.2+ (tested with LuaJIT and Lua 5.4)

local passed, failed, total = 0, 0, 0

local function assert_near(actual, expected, epsilon, msg)
  total = total + 1
  epsilon = epsilon or 1e-6
  if math.abs(actual - expected) <= epsilon then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format(
      "FAIL: %s\n  expected: %s\n  actual:   %s\n",
      msg or "assertion", tostring(expected), tostring(actual)))
  end
end

local function assert_eq(actual, expected, msg)
  total = total + 1
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format(
      "FAIL: %s\n  expected: %s\n  actual:   %s\n",
      msg or "assertion", tostring(expected), tostring(actual)))
  end
end

local function assert_true(val, msg)
  total = total + 1
  if val then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL: %s (got %s)\n", msg or "expected truthy", tostring(val)))
  end
end

local function assert_false(val, msg)
  total = total + 1
  if not val then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL: %s (got %s)\n", msg or "expected falsy", tostring(val)))
  end
end

local function section(name)
  io.write("\n--- " .. name .. " ---\n")
end

---------------------------------------------------------------------------
-- Bootstrap: mock the lite-xl module environment
---------------------------------------------------------------------------

-- Minimal common module
local common = {}
function common.clamp(n, lo, hi) return math.max(math.min(n, hi), lo) end
function common.lerp(a, b, t) return a + (b - a) * t end
function common.round(n) return n >= 0 and math.floor(n + 0.5) or math.ceil(n - 0.5) end

-- Minimal config
local config = {
  transitions = false,  -- disable animations for deterministic tests
  disabled_transitions = { scroll = false },
  fps = 60,
  animation_rate = 1.0,
}

-- Minimal style
local style = {
  scrollbar_size = 4,
  expanded_scrollbar_size = 12,
  minimum_thumb_size = 20,
  contracted_scrollbar_margin = 8,
  expanded_scrollbar_margin = 12,
  scrollbar_track = { 0, 0, 0, 255 },
  scrollbar = { 100, 100, 100, 255 },
  scrollbar2 = { 200, 200, 200, 255 },
}

-- Minimal core (just needs .redraw)
local core = { redraw = false }

-- Register mocks in package.loaded so require() finds them
package.loaded["core"] = core
package.loaded["core.common"] = common
package.loaded["core.config"] = config
package.loaded["core.style"] = style

-- Set up package path. Run from the project root: lua tests/test_scrollbar.lua
package.path = "data/?.lua;data/?/init.lua;" .. package.path

local Object = require "core.object"
package.loaded["core.object"] = Object

local Scrollbar = require "core.scrollbar"

---------------------------------------------------------------------------
-- Test 1: Coordinate roundtrip for all direction/alignment combinations
---------------------------------------------------------------------------

section("Coordinate roundtrip: real_to_normal -> normal_to_real")

local directions = { "v", "h" }
local alignments = { "s", "e" }
local test_points = {
  { 50, 80, 10, 15 },
  { 0, 0, 0, 0 },
  { 100, 200, 30, 40 },
  { 7.5, 12.3, 4.1, 8.7 },
}

for _, dir in ipairs(directions) do
  for _, align in ipairs(alignments) do
    local sb = Scrollbar({ direction = dir, alignment = align })
    sb:set_size(10, 20, 300, 400, 1000)
    local label = string.format("direction=%s alignment=%s", dir, align)

    for _, pt in ipairs(test_points) do
      local rx, ry, rw, rh = pt[1], pt[2], pt[3], pt[4]
      local nx, ny, nw, nh = sb:real_to_normal(rx, ry, rw, rh)
      local bx, by, bw, bh = sb:normal_to_real(nx, ny, nw, nh)
      assert_near(bx, rx, 1e-9, string.format("%s roundtrip x for (%s,%s,%s,%s)", label, rx, ry, rw, rh))
      assert_near(by, ry, 1e-9, string.format("%s roundtrip y for (%s,%s,%s,%s)", label, rx, ry, rw, rh))
      assert_near(bw, rw, 1e-9, string.format("%s roundtrip w for (%s,%s,%s,%s)", label, rx, ry, rw, rh))
      assert_near(bh, rh, 1e-9, string.format("%s roundtrip h for (%s,%s,%s,%s)", label, rx, ry, rw, rh))
    end
  end
end

---------------------------------------------------------------------------
-- Test 2: normal_to_real roundtrip (the other direction)
---------------------------------------------------------------------------

section("Coordinate roundtrip: normal_to_real -> real_to_normal")

for _, dir in ipairs(directions) do
  for _, align in ipairs(alignments) do
    local sb = Scrollbar({ direction = dir, alignment = align })
    sb:set_size(10, 20, 300, 400, 1000)
    local label = string.format("direction=%s alignment=%s", dir, align)

    for _, pt in ipairs(test_points) do
      local nx, ny, nw, nh = pt[1], pt[2], pt[3], pt[4]
      local rx, ry, rw, rh = sb:normal_to_real(nx, ny, nw, nh)
      local bx, by, bw, bh = sb:real_to_normal(rx, ry, rw, rh)
      assert_near(bx, nx, 1e-9, string.format("%s inverse roundtrip x for (%s,%s,%s,%s)", label, nx, ny, nw, nh))
      assert_near(by, ny, 1e-9, string.format("%s inverse roundtrip y for (%s,%s,%s,%s)", label, nx, ny, nw, nh))
      assert_near(bw, nw, 1e-9, string.format("%s inverse roundtrip w for (%s,%s,%s,%s)", label, nx, ny, nw, nh))
      assert_near(bh, nh, 1e-9, string.format("%s inverse roundtrip h for (%s,%s,%s,%s)", label, nx, ny, nw, nh))
    end
  end
end

---------------------------------------------------------------------------
-- Test 3: Drag stability — percent must not jump when expand_percent
--         would otherwise animate during a drag.
---------------------------------------------------------------------------

section("Drag stability: percent constant during drag")

for _, dir in ipairs(directions) do
  local sb = Scrollbar({ direction = dir, alignment = "e" })
  sb:set_size(0, 0, 200, 300, 1000)
  sb.expand_percent = 0  -- start contracted
  sb:set_percent(0.5)
  -- Force a full update cycle to compute normal_rect
  sb:update()

  -- Simulate press on the thumb
  local tx, ty, tw, th = sb:get_thumb_rect()
  local cx, cy  -- center of thumb in screen coords
  if dir == "v" then
    cx, cy = tx + tw / 2, ty + th / 2
  else
    cx, cy = tx + tw / 2, ty + th / 2
  end

  local press_result = sb:on_mouse_pressed("left", cx, cy, 1)
  assert_true(press_result, string.format("[%s] press on thumb returns truthy", dir))
  assert_true(sb.dragging, string.format("[%s] dragging flag set after press", dir))
  assert_near(sb.expand_percent, 1.0, 1e-9,
    string.format("[%s] expand_percent snapped to 1 on press", dir))

  -- Record the percent at the current mouse position
  local percent1 = sb:on_mouse_moved(cx, cy, 0, 0)
  assert_true(type(percent1) == "number", string.format("[%s] mouse_moved returns percent while dragging", dir))

  -- Even if something tried to shrink expand_percent, update() should keep it at 1
  sb.expand_percent = 0.3  -- simulate a bug trying to shrink it
  sb:update()
  assert_near(sb.expand_percent, 1.0, 1e-9,
    string.format("[%s] update() keeps expand_percent at 1 during drag", dir))

  -- The returned percent at the same position should be identical
  local percent2 = sb:on_mouse_moved(cx, cy, 0, 0)
  assert_near(percent2, percent1, 1e-9,
    string.format("[%s] percent stable across frames at same mouse pos", dir))

  sb:on_mouse_released("left", cx, cy)
  assert_false(sb.dragging, string.format("[%s] dragging cleared on release", dir))
end

---------------------------------------------------------------------------
-- Test 4: Hover detection consistency — vertical vs horizontal
---------------------------------------------------------------------------

section("Hover detection: vertical and horizontal consistency")

-- Create a vertical scrollbar at the end (right side)
local vsb = Scrollbar({ direction = "v", alignment = "e" })
vsb:set_size(0, 0, 200, 300, 1000)
vsb.expand_percent = 1
vsb:set_percent(0.3)
vsb:update()

local vthumb_x, vthumb_y, vthumb_w, vthumb_h = vsb:get_thumb_rect()
-- Point inside the thumb
local vover = vsb:overlaps(vthumb_x + vthumb_w / 2, vthumb_y + vthumb_h / 2)
assert_eq(vover, "thumb", "vertical: center of thumb detected as thumb")

-- Point on the track (above the thumb, within scrollbar width)
local vtrack_x = vthumb_x + vthumb_w / 2
local vtrack_y = vthumb_y - 10
if vtrack_y >= 0 then
  local vtrack_over = vsb:overlaps(vtrack_x, vtrack_y)
  assert_eq(vtrack_over, "track", "vertical: above thumb on track detected as track")
end

-- Create a horizontal scrollbar at the end (bottom)
local hsb = Scrollbar({ direction = "h", alignment = "e" })
hsb:set_size(0, 0, 200, 300, 1000)
hsb.expand_percent = 1
hsb:set_percent(0.3)
hsb:update()

local hthumb_x, hthumb_y, hthumb_w, hthumb_h = hsb:get_thumb_rect()
local hover = hsb:overlaps(hthumb_x + hthumb_w / 2, hthumb_y + hthumb_h / 2)
assert_eq(hover, "thumb", "horizontal: center of thumb detected as thumb")

local htrack_x = hthumb_x - 10
local htrack_y = hthumb_y + hthumb_h / 2
if htrack_x >= 0 then
  local htrack_over = hsb:overlaps(htrack_x, htrack_y)
  assert_eq(htrack_over, "track", "horizontal: left of thumb on track detected as track")
end

---------------------------------------------------------------------------
-- Test 5: Thumb rect stays inside view bounds for both orientations
---------------------------------------------------------------------------

section("Thumb rect inside view bounds")

for _, dir in ipairs(directions) do
  for _, align in ipairs(alignments) do
    local sb = Scrollbar({ direction = dir, alignment = align })
    sb:set_size(10, 20, 300, 400, 2000)
    sb.expand_percent = 1
    local label = string.format("direction=%s alignment=%s", dir, align)

    for pct = 0, 1, 0.25 do
      sb:set_percent(pct)
      sb:update()
      local tx, ty, tw, th = sb:get_thumb_rect()
      if tw > 0 and th > 0 then  -- only when scrollable
        assert_true(tx >= 10 - 0.5, string.format("%s pct=%.2f: thumb x >= view x", label, pct))
        assert_true(ty >= 20 - 0.5, string.format("%s pct=%.2f: thumb y >= view y", label, pct))
        assert_true(tx + tw <= 10 + 300 + 0.5, string.format("%s pct=%.2f: thumb right <= view right", label, pct))
        assert_true(ty + th <= 20 + 400 + 0.5, string.format("%s pct=%.2f: thumb bottom <= view bottom", label, pct))
      end
    end
  end
end

---------------------------------------------------------------------------
-- Test 6: Scaled sizes — ensure coordinate math works with non-default sizes
---------------------------------------------------------------------------

section("Scaled sizes: 2x scale factor")

local SCALE = 2
local sb_scaled = Scrollbar({
  direction = "h",
  alignment = "e",
  contracted_size = 4 * SCALE,
  expanded_size = 12 * SCALE,
  minimum_thumb_size = 20 * SCALE,
  contracted_margin = 8 * SCALE,
  expanded_margin = 12 * SCALE,
})
sb_scaled:set_size(0, 0, 400, 600, 3000)
sb_scaled.expand_percent = 1
sb_scaled:set_percent(0.5)
sb_scaled:update()

local stx, sty, stw, sth = sb_scaled:get_thumb_rect()
assert_true(stw > 0 and sth > 0, "scaled horizontal: thumb has positive size")
assert_true(stx >= 0, "scaled horizontal: thumb x >= 0")
assert_true(sty >= 0, "scaled horizontal: thumb y >= 0")
assert_true(stx + stw <= 400 + 0.5, "scaled horizontal: thumb fits in view width")
assert_true(sty + sth <= 600 + 0.5, "scaled horizontal: thumb fits in view height")

-- Hover should work at the thumb center
local scaled_over = sb_scaled:overlaps(stx + stw / 2, sty + sth / 2)
assert_eq(scaled_over, "thumb", "scaled horizontal: hover at thumb center works")

-- Drag should produce stable percent
sb_scaled:on_mouse_pressed("left", stx + stw / 2, sty + sth / 2, 1)
local sp1 = sb_scaled:on_mouse_moved(stx + stw / 2 + 50, sty + sth / 2, 50, 0)
local sp2 = sb_scaled:on_mouse_moved(stx + stw / 2 + 50, sty + sth / 2, 0, 0)
assert_near(sp1, sp2, 1e-9, "scaled horizontal: percent stable at same position across calls")
sb_scaled:on_mouse_released("left", stx + stw / 2 + 50, sty + sth / 2)

---------------------------------------------------------------------------
-- Test 7: Track click returns correct percent
---------------------------------------------------------------------------

section("Track click: percent calculation")

local tsb = Scrollbar({ direction = "v", alignment = "e" })
tsb:set_size(0, 0, 200, 400, 1600)
tsb.expand_percent = 1
tsb:update()

-- The track spans the full view height (0..400).
-- Thumb size = max(20, 400^2/1600) = max(20, 100) = 100
-- Clicking at y=200 (center) should produce percent close to 0.5
-- (accounting for the centering offset of half the thumb).
local track_pct = tsb:on_mouse_pressed("left", 196, 200, 1)
assert_true(type(track_pct) == "number", "track click returns a number (percent)")
if type(track_pct) == "number" then
  assert_near(track_pct, 0.5, 0.15, "track click at center ~ 0.5")
end
tsb:on_mouse_released("left", 196, 200)

-- Same test for horizontal
local thsb = Scrollbar({ direction = "h", alignment = "e" })
thsb:set_size(0, 0, 400, 200, 1600)
thsb.expand_percent = 1
thsb:update()

local htrack_pct = thsb:on_mouse_pressed("left", 200, 196, 1)
assert_true(type(htrack_pct) == "number", "horizontal track click returns a number (percent)")
if type(htrack_pct) == "number" then
  assert_near(htrack_pct, 0.5, 0.15, "horizontal track click at center ~ 0.5")
end
thsb:on_mouse_released("left", 200, 196)

---------------------------------------------------------------------------
-- Test 8: Drag produces monotonically changing percent
---------------------------------------------------------------------------

section("Drag monotonicity: percent changes smoothly with mouse position")

for _, dir in ipairs(directions) do
  local sb = Scrollbar({ direction = dir, alignment = "e" })
  sb:set_size(0, 0, 200, 400, 1600)
  sb.expand_percent = 1
  sb:set_percent(0.0)
  sb:update()
  local label = string.format("direction=%s", dir)

  local tx, ty, tw, th = sb:get_thumb_rect()
  local cx, cy = tx + tw / 2, ty + th / 2
  sb:on_mouse_pressed("left", cx, cy, 1)

  local prev_pct = sb:on_mouse_moved(cx, cy, 0, 0)
  local monotonic = true
  local steps = 20

  for i = 1, steps do
    local nx, ny = cx, cy
    if dir == "v" then
      ny = cy + (i / steps) * 200  -- move downward
    else
      nx = cx + (i / steps) * 200  -- move rightward
    end
    local pct = sb:on_mouse_moved(nx, ny, 0, 0)
    if type(pct) == "number" and pct < prev_pct - 1e-9 then
      monotonic = false
    end
    if type(pct) == "number" then
      prev_pct = pct
    end
  end

  assert_true(monotonic, string.format("%s: drag percent is monotonically non-decreasing", label))
  sb:on_mouse_released("left", cx, cy)
end

---------------------------------------------------------------------------
-- Test 9: h+s specific — the bug that was fixed
---------------------------------------------------------------------------

section("Regression: h+s coordinate roundtrip (the original bug)")

local hssb = Scrollbar({ direction = "h", alignment = "s" })
hssb:set_size(0, 0, 500, 300, 1500)

-- Verify that normal_to_real is a proper inverse of real_to_normal
-- Specifically for the h+s case which had the wrong flip axis.
local test_rects = {
  { 100, 50, 30, 20 },
  { 0, 0, 500, 300 },
  { 250, 150, 10, 10 },
  { 499, 299, 1, 1 },
}

for _, r in ipairs(test_rects) do
  local rx, ry, rw, rh = r[1], r[2], r[3], r[4]
  local nx, ny, nw, nh = hssb:real_to_normal(rx, ry, rw, rh)
  local bx, by, bw, bh = hssb:normal_to_real(nx, ny, nw, nh)
  assert_near(bx, rx, 1e-9, string.format("h+s roundtrip x for rect(%s,%s,%s,%s)", rx, ry, rw, rh))
  assert_near(by, ry, 1e-9, string.format("h+s roundtrip y for rect(%s,%s,%s,%s)", rx, ry, rw, rh))
  assert_near(bw, rw, 1e-9, string.format("h+s roundtrip w for rect(%s,%s,%s,%s)", rx, ry, rw, rh))
  assert_near(bh, rh, 1e-9, string.format("h+s roundtrip h for rect(%s,%s,%s,%s)", rx, ry, rw, rh))
end

-- Also verify the thumb draws in the correct position for h+s
hssb.expand_percent = 1
hssb:set_percent(0.5)
hssb:update()
local hstx, hsty, hstw, hsth = hssb:get_thumb_rect()
assert_true(hstw > 0 and hsth > 0, "h+s: thumb has positive size")
-- For h+s, the thumb should be at the top of the view (alignment=start)
assert_true(hsty >= 0 and hsty < 20, "h+s: thumb is near the top (start alignment)")
assert_true(hstx > 0 and hstx < 500, "h+s: thumb x is within view bounds")

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

io.write(string.format("\n=== Results: %d/%d passed, %d failed ===\n", passed, total, failed))
if failed > 0 then
  os.exit(1)
end
