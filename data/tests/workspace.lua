-- Regression tests for the workspace plugin's multi-project restore logic.
--
-- These tests are self-contained: they stub the parts of the editor runtime
-- that workspace.lua needs at load time, but load the *real* core.common so
-- the path math (normalize_path / is_absolute_path / relative_path) is the
-- same code that runs in the editor.
--
-- Run from the repository root with:  lua data/tests/workspace.lua

-- Globals the editor normally provides.
PATHSEP = "/"
HOME = "/home/me"

-- Make "core.*" and "plugins.*" resolvable from the data directory, regardless
-- of the current working directory the test is launched from.
local script = (arg and arg[0]) or "data/tests/workspace.lua"
local script_dir = script:match("^(.*)[/\\]") or "."
local data_dir = script_dir:match("^(.*)[/\\][^/\\]+$") or script_dir
package.path = data_dir .. "/?.lua;" .. data_dir .. "/?/init.lua;" .. package.path

-- Recording stubs for the bits of the runtime that restore_directories touches.
local added = {}
local logs = { error = {}, warn = {} }
local existing_dirs = {}

local function reset()
  added = {}
  logs = { error = {}, warn = {} }
  existing_dirs = {}
end

system = {
  get_file_info = function(path)
    if existing_dirs[path] then return { type = "dir" } end
    return nil
  end,
}

local core_stub = {
  run = function() end,
  projects = {},
  add_project = function(path)
    table.insert(added, path)
    return { path = path }
  end,
  error = function(fmt, ...)
    table.insert(logs.error, string.format(fmt, ...))
  end,
  warn = function(fmt, ...)
    table.insert(logs.warn, string.format(fmt, ...))
  end,
}

-- Stub everything workspace.lua requires at load time, except core.common,
-- which we deliberately let load from disk for faithful path handling.
package.preload["core"] = function() return core_stub end
package.preload["core.docview"] = function() return setmetatable({}, {}) end
package.preload["core.logview"] = function() return setmetatable({}, {}) end
package.preload["core.storage"] = function()
  return { keys = function() return {} end, load = function() end,
           save = function() end, clear = function() end }
end

local common = require "core.common"
local ws = require "plugins.workspace"

----------------------------------------------------------------------
-- Tiny assertion helpers.
----------------------------------------------------------------------
local failures = 0

local function check(cond, msg)
  if cond then
    print("  ok   - " .. msg)
  else
    failures = failures + 1
    print("  FAIL - " .. msg)
  end
end

local function eq(actual, expected, msg)
  check(actual == expected,
    string.format("%s (expected %q, got %q)", msg, tostring(expected), tostring(actual)))
end

local function eq_list(actual, expected, msg)
  local same = #actual == #expected
  if same then
    for i = 1, #expected do
      if actual[i] ~= expected[i] then same = false break end
    end
  end
  check(same, string.format("%s (expected [%s], got [%s])",
    msg, table.concat(expected, ", "), table.concat(actual, ", ")))
end

-- Mimics the previous, buggy behaviour: system.absolute_path resolves a
-- relative entry against the current working directory.
local function old_resolve(cwd, name)
  if common.is_absolute_path(name) then return common.normalize_path(name) end
  return common.normalize_path(cwd .. PATHSEP .. name)
end

----------------------------------------------------------------------
print("workspace: additional directories are resolved independently of cwd")
do
  reset()
  local root = "/projects/app"
  local extra = "/projects/lib"           -- sibling of the root project
  core_stub.projects = { { path = root }, { path = extra } }

  local saved = ws.save_directories(root)
  eq(saved[1], "../lib", "directory is stored relative to the root project")

  -- The old code worked only when launched from the root project directory...
  eq(old_resolve(root, saved[1]), extra, "old behaviour was correct when cwd == root project")
  -- ...and silently relocated the project from any other launch directory.
  eq(old_resolve("/somewhere/else", saved[1]), "/somewhere/lib",
    "old behaviour relocated the project when cwd != root project")

  -- The fix resolves against the root project, so cwd is irrelevant.
  eq(ws.resolve_project_dir(root, saved[1]), extra,
    "fixed resolution recovers the original absolute path")
end

----------------------------------------------------------------------
print("workspace: a saved workspace restores correctly after the tree is moved")
do
  reset()
  -- Save while the project lives in one location.
  local root_a = "/home/me/app"
  core_stub.projects = {
    { path = root_a },
    { path = "/home/me/shared" },   -- sibling
    { path = "/home/me/app/vendor" }, -- nested
  }
  local saved = ws.save_directories(root_a)
  eq_list(saved, { "../shared", "vendor" }, "relative encoding captures sibling and nested dirs")

  -- Restore after the whole tree has been moved to a new root.
  local root_b = "/srv/app"
  local restored = {}
  for _, name in ipairs(saved) do
    table.insert(restored, ws.resolve_project_dir(root_b, name))
  end
  eq_list(restored, { "/srv/shared", "/srv/app/vendor" },
    "extra projects relocate together with the new root")
end

----------------------------------------------------------------------
print("workspace: absolute entries are preserved (old data / cross-drive)")
do
  reset()
  local root = "/srv/app"
  eq(ws.resolve_project_dir(root, "/opt/global-lib"), "/opt/global-lib",
    "absolute entry is kept as-is, not re-based under the root")
end

----------------------------------------------------------------------
print("workspace: missing directories warn and are skipped without dropping the rest")
do
  reset()
  local root = "/projects/app"
  existing_dirs["/projects/good"] = true   -- exists on disk
  -- "/projects/missing" intentionally does not exist.
  core_stub.projects = { { path = root } }

  ws.restore_directories(root, { "../good", "../missing" })

  eq_list(added, { "/projects/good" },
    "the valid project is added even though an earlier/other entry is missing")
  eq(#logs.warn, 1, "exactly one warning is emitted for the missing directory")
  check(logs.warn[1]:find("/projects/missing", 1, true) ~= nil,
    "the warning names the missing directory")
  eq(#logs.error, 0, "a missing directory is a warning, not a hard error")
end

----------------------------------------------------------------------
if failures == 0 then
  print("\nALL TESTS PASSED")
  os.exit(0)
else
  print(string.format("\n%d CHECK(S) FAILED", failures))
  os.exit(1)
end
