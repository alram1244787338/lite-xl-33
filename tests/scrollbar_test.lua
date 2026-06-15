-- Minimal regression test for data/core/scrollbar.lua
--
-- Locks the scrollbar mouse-interaction contract that views depend on:
--   * vertical and horizontal drag map mouse movement to the same percent
--   * hover detection works on both orientations (and rejects misses)
--   * the real<->normal conversions are exact inverses for every orientation
--   * drag stays continuous/finite when the thumb is resized mid-drag, or when
--     the track is too short for the thumb to move (no NaN, no teleport)
--   * get_track_rect() still reports the bar thickness where DocView reads it
--
-- Run from the repo root:  lua tests/scrollbar_test.lua
-- It stubs the few core modules the scrollbar pulls in so it can run headless.

-- Resolve the repo's data/ directory relative to this script so the test works
-- regardless of the current working directory.
local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../data/?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Stub the dependencies of core.scrollbar (registered before it is required so
-- the preload searcher wins over the file searcher).
-- ---------------------------------------------------------------------------
package.loaded["core"] = { redraw = false }

package.loaded["core.common"] = {
  clamp = function(n, lo, hi) return math.max(math.min(n, hi), lo) end,
  lerp = function(a, b, t) return a + (b - a) * t end,
  round = function(n) return math.floor(n + 0.5) end,
}

package.loaded["core.config"] = {
  transitions = false, -- settle animations instantly -> deterministic sizes
  disabled_transitions = {},
  fps = 60,
  animation_rate = 1,
}

-- Sizes are normally pre-multiplied by SCALE; the scrollbar only ever reads
-- these, so changing them is exactly how a different UI scale looks to it.
local style = {
  scrollbar_size = 4,
  expanded_scrollbar_size = 12,
  minimum_thumb_size = 20,
  contracted_scrollbar_margin = 8,
  expanded_scrollbar_margin = 12,
  -- colors are only touched by draw(), which the test never calls
  scrollbar = {0, 0, 0, 0}, scrollbar2 = {0, 0, 0, 0}, scrollbar_track = {0, 0, 0, 0},
}
package.loaded["core.style"] = style

-- Faithful (minimal) copy of core.object's class machinery.
local Object = {}
Object.__index = Object
function Object:new() end
function Object:extend()
  local cls = {}
  for k, v in pairs(self) do
    if tostring(k):find("__") == 1 then cls[k] = v end
  end
  cls.__index = cls
  cls.super = self
  setmetatable(cls, self)
  return cls
end
function Object:__call(...)
  local obj = setmetatable({}, self)
  obj:new(...)
  return obj
end
function Object:__tostring() return "Object" end
package.loaded["core.object"] = Object

local Scrollbar = require "core.scrollbar"

-- ---------------------------------------------------------------------------
-- Tiny assertion harness
-- ---------------------------------------------------------------------------
local failures, total = 0, 0
local EPS = 1e-6

local function fail(msg)
  failures = failures + 1
  io.write(string.format("  FAIL: %s\n", msg))
end

local function ok(cond, msg)
  total = total + 1
  if not cond then fail(msg) end
end

local function near(actual, expected, msg)
  total = total + 1
  if type(actual) ~= "number" or actual ~= actual
     or math.abs(actual - expected) > EPS then
    fail(string.format("%s (expected %s, got %s)", msg, tostring(expected), tostring(actual)))
  end
end

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function make(direction, x, y, w, h, scrollable, alignment)
  local sb = Scrollbar({direction = direction, alignment = alignment or "e"})
  sb:set_size(x, y, w, h, scrollable)
  sb:set_percent(0)
  sb:update() -- not hovering/dragging -> contracted (expand_percent == 0)
  return sb
end

-- Normal-space [start, end] of the thumb along the scroll axis for the current percent.
local function thumb_along_span(sb)
  local _, along, _, along_size = sb:_get_thumb_rect_normal()
  return along, along + along_size
end

-- ---------------------------------------------------------------------------
-- 1. Vertical drag: dragging the thumb maps movement to percent continuously.
-- ---------------------------------------------------------------------------
do
  -- view 100x200, scrollable 400 -> thumb length 100, thickness 4, x in [96,100]
  local sb = make("v", 0, 0, 100, 200, 400)

  ok(sb:overlaps(98, 10) == "thumb", "v: point on thumb should hover thumb")
  ok(sb:overlaps(10, 10) == nil, "v: point in content should not hover scrollbar")

  ok(sb:on_mouse_pressed("left", 98, 10) == true, "v: pressing thumb returns true")
  near(sb:on_mouse_moved(98, 10, 0, 0), 0.0, "v: no movement keeps percent at press point")
  near(sb:on_mouse_moved(98, 60, 0, 50), 0.5, "v: moving half the travel -> 0.5")
  near(sb:on_mouse_moved(98, 110, 0, 50), 1.0, "v: moving full travel -> 1.0")
  near(sb:on_mouse_moved(98, 10, 0, -100), 0.0, "v: dragging back -> 0.0 (continuous)")
  sb:on_mouse_released("left", 98, 10)
  ok(sb.dragging == false, "v: release clears dragging")
end

-- ---------------------------------------------------------------------------
-- 2. Horizontal drag: same logical drag distance yields the same percent.
-- ---------------------------------------------------------------------------
do
  -- view 200x100, scrollable 400 -> thumb length 100, thickness 4, y in [96,100]
  local sb = make("h", 0, 0, 200, 100, 400)

  ok(sb:overlaps(10, 98) == "thumb", "h: point on (bottom) thumb should hover thumb")
  ok(sb:overlaps(10, 10) == nil, "h: point in content should not hover scrollbar")

  ok(sb:on_mouse_pressed("left", 10, 98) == true, "h: pressing thumb returns true")
  near(sb:on_mouse_moved(60, 98, 50, 0), 0.5, "h: moving half the travel -> 0.5 (parity with v)")
  near(sb:on_mouse_moved(110, 98, 50, 0), 1.0, "h: moving full travel -> 1.0")
  near(sb:on_mouse_moved(10, 98, -100, 0), 0.0, "h: dragging back -> 0.0")
end

-- ---------------------------------------------------------------------------
-- 3. Hover + track-click parity.
-- ---------------------------------------------------------------------------
do
  local sb = make("v", 0, 0, 100, 200, 400)
  -- below the thumb (along 150) but over the track column -> "track"
  ok(sb:overlaps(98, 150) == "track", "v: point on track-not-thumb hovers track")
  -- clicking the track returns a percent that centers the thumb on the cursor
  local p = sb:on_mouse_pressed("left", 98, 150)
  ok(type(p) == "number" and p > 0 and p <= 1, "v: track click returns a percent in (0,1]")

  local sb2 = make("v", 0, 0, 100, 200, 400)
  ok(sb2:on_mouse_moved(98, 10, 0, 0), "v: hovering thumb returns truthy")
  ok(sb2.hovering.thumb and sb2.hovering.track, "v: hover flags set over thumb")
  ok(not sb2:on_mouse_moved(10, 10, -88, 0), "v: moving off returns falsy")
  ok(not sb2.hovering.thumb and not sb2.hovering.track, "v: hover flags cleared off thumb")
end

-- ---------------------------------------------------------------------------
-- 4. Scaled UI: a thicker bar (bigger style sizes) must not change the percent
--    mapping, and hover must still land on the thicker thumb.
-- ---------------------------------------------------------------------------
do
  local saved = {
    style.scrollbar_size, style.expanded_scrollbar_size, style.minimum_thumb_size,
    style.contracted_scrollbar_margin, style.expanded_scrollbar_margin,
  }
  -- simulate ~2x SCALE
  style.scrollbar_size = 8
  style.expanded_scrollbar_size = 24
  style.minimum_thumb_size = 40
  style.contracted_scrollbar_margin = 16
  style.expanded_scrollbar_margin = 24

  local sb = make("v", 0, 0, 100, 200, 400) -- thumb length still 100 (> min 40)
  ok(sb:overlaps(98, 10) == "thumb", "scaled: thicker thumb still detects hover")
  ok(sb:on_mouse_pressed("left", 98, 10) == true, "scaled: press thumb")
  near(sb:on_mouse_moved(98, 60, 0, 50), 0.5, "scaled: percent mapping unchanged by thickness")

  style.scrollbar_size, style.expanded_scrollbar_size, style.minimum_thumb_size,
    style.contracted_scrollbar_margin, style.expanded_scrollbar_margin =
    saved[1], saved[2], saved[3], saved[4], saved[5]
end

-- ---------------------------------------------------------------------------
-- 5. Robustness: resizing the thumb mid-drag stays finite, in range, and keeps
--    the grabbed point under the cursor (no sudden percent jump / teleport).
-- ---------------------------------------------------------------------------
do
  local sb = make("v", 0, 0, 100, 200, 400) -- thumb length 100
  -- grab the thumb at its centre (y = 50)
  sb:on_mouse_pressed("left", 98, 50)

  -- content grows: scrollable 400 -> 1000, thumb shrinks to length 40
  sb:set_size(0, 0, 100, 200, 1000)
  local p = sb:on_mouse_moved(98, 50, 0, 0)
  ok(finite(p), "resize: percent stays finite after thumb resize")
  ok(p >= 0 and p <= 1, "resize: percent stays within [0,1]")

  -- the cursor (along = 50) must still sit on the (now shorter) thumb
  sb:set_percent(p)
  local a0, a1 = thumb_along_span(sb)
  ok(50 >= a0 - EPS and 50 <= a1 + EPS, "resize: grabbed point stays under the cursor")
end

-- ---------------------------------------------------------------------------
-- 6. Degenerate range: track shorter than the minimum thumb -> no NaN.
-- ---------------------------------------------------------------------------
do
  local sb = make("v", 0, 0, 100, 15, 400) -- track 15 < min thumb 20
  ok(sb:overlaps(98, 5) == "thumb", "degenerate: tiny thumb still hoverable")
  sb:on_mouse_pressed("left", 98, 5)
  local p = sb:on_mouse_moved(98, 12, 0, 7)
  ok(finite(p), "degenerate: drag returns a finite value (no NaN)")
  near(p, 0, "degenerate: immovable thumb clamps to 0")
  near(sb:_drag_percent(5, 20), 0, "degenerate: _drag_percent guards zero range")
end

-- ---------------------------------------------------------------------------
-- 7. Empty (non-scrollable): no scrollbar -> no hover anywhere.
-- ---------------------------------------------------------------------------
do
  local sb = make("v", 0, 0, 100, 200, 100) -- scrollable <= height -> nothing to scroll
  ok(sb:overlaps(0, 0) == nil, "empty: origin does not falsely hover")
  ok(sb:overlaps(98, 10) == nil, "empty: bar column does not hover when nothing scrolls")
end

-- ---------------------------------------------------------------------------
-- 8. real<->normal rectangle round-trip is exact for every orientation, and
--    get_track_rect reports the bar thickness where DocView reads it.
-- ---------------------------------------------------------------------------
do
  for _, dir in ipairs({"v", "h"}) do
    for _, al in ipairs({"e", "s"}) do
      local sb = make(dir, 10, 20, 100, 200, 400, al)
      local rx, ry, rw, rh = 20, 40, 10, 30
      local bx, by, bw, bh = sb:normal_to_real(sb:real_to_normal(rx, ry, rw, rh))
      local tag = dir .. "/" .. al
      near(bx, rx, tag .. ": rect round-trip x")
      near(by, ry, tag .. ": rect round-trip y")
      near(bw, rw, tag .. ": rect round-trip w")
      near(bh, rh, tag .. ": rect round-trip h")
    end
  end

  -- DocView reads the vertical bar width as the 3rd return, the horizontal bar
  -- height as the 4th return. Both must equal the (contracted) thickness.
  local v = make("v", 0, 0, 100, 200, 400)
  local _, _, vw = v:get_track_rect()
  near(vw, style.scrollbar_size, "contract: vertical track width == thickness (DocView contract)")

  local h = make("h", 0, 0, 200, 100, 400)
  local _, _, _, hh = h:get_track_rect()
  near(hh, style.scrollbar_size, "contract: horizontal track height == thickness (DocView contract)")
end

-- ---------------------------------------------------------------------------
-- 9. Delta transform: deltas only swap axes / flip the mirrored axis sign;
--    they never pick up the rectangle origin (the old bug).
-- ---------------------------------------------------------------------------
do
  local function delta(dir, al, dx, dy)
    local sb = make(dir, 10, 20, 100, 200, 400, al)
    return sb:real_to_normal_delta(dx, dy)
  end
  local ax, ay = delta("v", "e", 3, 7); near(ax, 3, "delta v/e across"); near(ay, 7, "delta v/e along")
  ax, ay = delta("v", "s", 3, 7);       near(ax, -3, "delta v/s across flips"); near(ay, 7, "delta v/s along")
  ax, ay = delta("h", "e", 3, 7);       near(ax, 7, "delta h/e swaps"); near(ay, 3, "delta h/e swaps")
  ax, ay = delta("h", "s", 3, 7);       near(ax, -7, "delta h/s swap+flip"); near(ay, 3, "delta h/s swap+flip")
end

-- ---------------------------------------------------------------------------
io.write(string.format("\nscrollbar_test: %d checks, %d failures\n", total, failures))
os.exit(failures == 0 and 0 or 1)
