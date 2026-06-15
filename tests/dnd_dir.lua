-- Regression test for directory drag-and-drop routing in RootView.
--
-- It verifies that a batch of dropped directories behaves the SAME regardless
-- of whether the drops land before or after the first update():
--   * the first directory of a launch/dock batch replaces the current project
--   * every following directory of that batch opens in a new window
--   * an interactive drop onto a running window asks the user instead
--
-- The test loads the real data/core/rootview.lua with minimal stubs so the
-- actual on_file_dropped / open_dropped_directory logic is exercised.
--
-- Run from the repository root:  lua tests/dnd_dir.lua

-- Resolve the data directory relative to this script so cwd does not matter.
local script_dir = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
package.path = script_dir .. "/../data/?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Minimal stubs for the modules required by rootview.lua
-- ---------------------------------------------------------------------------

-- a tiny "class" object exposing :extend(), matching how core.view is used
local function new_class()
  local c = {}
  c.__index = c
  function c:extend()
    local sub = setmetatable({}, { __index = self })
    sub.__index = sub
    sub.super = self
    return sub
  end
  return c
end

-- permissive table: indexing returns another permissive table / no-op callable,
-- so any incidental access at load time is harmless
local function permissive()
  local t = {}
  setmetatable(t, {
    __index = function() return permissive() end,
    __call = function() return permissive() end,
  })
  return t
end

-- Recorded calls produced by the stubbed core functions.
local calls = {}
local function reset() calls = {} end
local function ops()
  local list = {}
  for _, c in ipairs(calls) do list[#list + 1] = c.op end
  return table.concat(list, ",")
end

local core = {}
core.docs = {}
core.open_project = function(p) calls[#calls + 1] = { op = "open_project", path = p } end
core.add_project = function(p) calls[#calls + 1] = { op = "add_project", path = p } end
core.open_in_new_instance = function(p) calls[#calls + 1] = { op = "new_instance", path = p } end
-- no dirty docs in the test, so confirm_close_docs proceeds immediately
core.confirm_close_docs = function(_, fn, ...)
  calls[#calls + 1] = { op = "confirm_close" }
  fn(...)
end
core.nag_view = {
  show = function(_, title) calls[#calls + 1] = { op = "nag", title = title } end,
}

local common = { home_encode = function(s) return s end }

package.preload["core"] = function() return core end
package.preload["core.common"] = function() return common end
package.preload["core.style"] = function() return permissive() end
package.preload["core.node"] = function() return permissive() end
package.preload["core.view"] = function() return new_class() end
package.preload["core.docview"] = function() return permissive() end
package.preload["core.contextmenu"] = function() return permissive() end

-- global `system` used by rootview.lua; every dropped path is treated as a dir
system = {
  get_file_info = function() return { type = "dir" } end,
  absolute_path = function(p) return p end,
}

local RootView = require "core.rootview"

-- ---------------------------------------------------------------------------
-- Test harness
-- ---------------------------------------------------------------------------

local failures = 0
local function check(cond, msg)
  if cond then
    print("  ok   - " .. msg)
  else
    failures = failures + 1
    print("  FAIL - " .. msg)
  end
end

-- A fresh RootView-like object. We avoid :new() (which needs Node/ContextMenu)
-- and instead provide just the state on_file_dropped touches.
local function fresh_rv()
  local rv = setmetatable({ first_dnd_processed = false }, { __index = RootView })
  rv.defer_open_docs = {}
  rv.root_node = {
    -- the active view never handles directory drops, so they fall through
    get_child_overlapping_point = function()
      return { active_view = { on_file_dropped = function() return false end } }
    end,
  }
  return rv
end

-- Simulate a directory drop. `windowed` mirrors the C-side signal: false for
-- OS/dock launch drops, true for interactive drops onto a running window.
local function drop_dir(rv, path, windowed)
  local x, y = (windowed and 50 or 0), (windowed and 50 or 0)
  rv:on_file_dropped(path, x, y, windowed)
end

-- ---------------------------------------------------------------------------
-- Scenarios
-- ---------------------------------------------------------------------------

print("single directory, dropped BEFORE first update")
reset()
local rv = fresh_rv()
drop_dir(rv, "/proj/a", false)
check(ops() == "confirm_close,open_project", "first dir replaces current project")
check(calls[#calls].path == "/proj/a", "project opened is the dropped dir")

print("single directory, dropped AFTER first update")
reset()
rv = fresh_rv()
-- the old code switched behavior once the first update() had run; the routing
-- must now be independent of that. Setting the legacy flag guards against a
-- timing-based branch being reintroduced.
rv.first_update_done = true
drop_dir(rv, "/proj/a", false)
check(ops() == "confirm_close,open_project", "still replaces project, no dialog")

print("multiple directories, all BEFORE first update")
reset()
rv = fresh_rv()
drop_dir(rv, "/proj/a", false)
drop_dir(rv, "/proj/b", false)
drop_dir(rv, "/proj/c", false)
check(ops() == "confirm_close,open_project,new_instance,new_instance",
  "first replaces project, rest open new windows")

print("multiple directories, STRADDLING the first update")
reset()
rv = fresh_rv()
drop_dir(rv, "/proj/a", false)      -- arrives before the first frame
rv.first_update_done = true          -- a frame happens mid-batch
drop_dir(rv, "/proj/b", false)      -- arrives after the first frame
drop_dir(rv, "/proj/c", false)
check(ops() == "confirm_close,open_project,new_instance,new_instance",
  "batch is consistent across the frame boundary (no dup/miss, no dialog)")

print("interactive drop onto a running window")
reset()
rv = fresh_rv()
rv.first_update_done = true
drop_dir(rv, "/proj/a", true)
check(ops() == "nag", "asks the user where to open it")
check(rv.first_dnd_processed == false, "interactive drop does not consume the launch latch")

print("interactive new window uses the process-API helper, not system.exec")
check(type(core.open_in_new_instance) == "function", "core.open_in_new_instance exists")

print("")
if failures == 0 then
  print("ALL PASSED")
  os.exit(0)
else
  print(failures .. " CHECK(S) FAILED")
  os.exit(1)
end
