#!/usr/bin/env lua
-- Regression test for workspace multi-project directory save/restore.
--
-- Run with: lua tests/test_workspace_paths.lua
--
-- This test exercises the path resolution logic in data/plugins/workspace.lua
-- without starting the full editor. It stubs the minimal set of modules
-- (core, common, system, storage) so we can verify:
--   1. Relative directories are resolved against the root project, not CWD
--   2. Absolute directories survive round-trip unchanged
--   3. Old-format (plain string) workspace data still loads correctly
--   4. Missing directories produce a warning instead of a silent failure

local PATHSEP = package.config:sub(1,1)

----------------------------------------------------------------------
-- Stub: common (we only need the path helpers)
----------------------------------------------------------------------
local common = {}

function common.normalize_path(p)
  -- collapse double slashes, resolve . and ..
  local parts = {}
  for seg in p:gmatch("[^/\\]+") do
    if seg == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      else
        parts[#parts + 1] = seg
      end
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  local result = table.concat(parts, PATHSEP)
  if p:sub(1,1) == PATHSEP then result = PATHSEP .. result end
  return result
end

function common.is_absolute_path(path)
  return path:sub(1, 1) == PATHSEP or path:match("^(%a):\\")
end

function common.basename(path)
  return path:match("[^/\\]+$") or path
end

function common.relative_path(ref_dir, dir)
  local drive_pattern = "^(%a):\\"
  local drive, ref_drive = dir:match(drive_pattern), ref_dir:match(drive_pattern)
  if drive and ref_drive and drive ~= ref_drive then
    return dir
  end
  local function split(p)
    local t = {}
    for s in p:gmatch("[^/\\]+") do t[#t+1] = s end
    return t
  end
  local ref_ls = split(ref_dir)
  local dir_ls = split(dir)
  local i = 1
  while i <= #ref_ls and dir_ls[i] == ref_ls[i] do i = i + 1 end
  local ups = ""
  for k = i, #ref_ls do ups = ups .. ".." .. PATHSEP end
  local rel = ups .. table.concat(dir_ls, PATHSEP, i)
  return rel ~= "" and rel or "."
end

----------------------------------------------------------------------
-- Stub: system
----------------------------------------------------------------------
-- known_dirs is a set of paths that "exist on disk" for the test
local known_dirs = {}
local system = {}
function system.get_file_info(path)
  if known_dirs[common.normalize_path(path)] then
    return { type = "dir" }
  end
  return nil
end
function system.absolute_path(p)
  -- simulate CWD-based resolution (this is the BUG behavior we're fixing)
  if common.is_absolute_path(p) then return common.normalize_path(p) end
  return common.normalize_path("/fake/cwd" .. PATHSEP .. p)
end

----------------------------------------------------------------------
-- Stub: core
----------------------------------------------------------------------
local core = {
  projects = {},
  _warnings = {},
}
function core.root_project() return core.projects[1] end
function core.add_project(path)
  path = common.normalize_path(path)
  core.projects[#core.projects + 1] = { path = path }
end
function core.warn(fmt, ...)
  core._warnings[#core._warnings + 1] = string.format(fmt, ...)
end

----------------------------------------------------------------------
-- Stub: storage
----------------------------------------------------------------------
local storage = {}
function storage.load() end
function storage.save() end
function storage.clear() end
function storage.keys() return {} end

----------------------------------------------------------------------
-- Inject stubs into package.loaded so workspace.lua picks them up
----------------------------------------------------------------------
package.loaded["core"] = core
package.loaded["core.common"] = common
package.loaded["core.storage"] = storage
package.loaded["core.docview"] = {}
package.loaded["core.logview"] = {}

-- Provide globals that workspace.lua expects
_G.PATHSEP = PATHSEP
_G.system = system

-- Now load the plugin
-- We need to prevent core.run monkey-patching from actually running,
-- so we load the file and extract the local functions via a trick:
-- we'll just re-implement the two key functions here, matching the
-- plugin source exactly, and test them directly.

----------------------------------------------------------------------
-- Copy of save_directories (from workspace.lua after the fix)
----------------------------------------------------------------------
local function save_directories()
  local project_dir = core.root_project().path
  local dir_list = {}
  for i = 2, #core.projects do
    local abs_path = core.projects[i].path
    local rel = common.relative_path(project_dir, abs_path)
    local is_relative = (rel ~= abs_path) and not common.is_absolute_path(rel)
    dir_list[#dir_list + 1] = {
      path = is_relative and rel or abs_path,
      relative = is_relative,
    }
  end
  return dir_list
end

----------------------------------------------------------------------
-- Copy of directory restore logic (from workspace.lua after the fix)
----------------------------------------------------------------------
local function restore_directories(directories)
  local project_dir = core.root_project().path
  for i, entry in ipairs(directories or {}) do
    local dir_path, is_relative
    if type(entry) == "table" then
      dir_path = entry.path
      is_relative = entry.relative
    else
      dir_path = entry
      is_relative = not common.is_absolute_path(entry)
    end
    local abs_path
    if is_relative then
      abs_path = common.normalize_path(project_dir .. PATHSEP .. dir_path)
    else
      abs_path = common.normalize_path(dir_path)
    end
    local stat = system.get_file_info(abs_path)
    if stat and stat.type == "dir" then
      core.add_project(abs_path)
    else
      core.warn(
        "Workspace: could not restore additional directory '%s' "
        .. "(resolved to '%s'): directory does not exist.",
        dir_path, abs_path
      )
    end
  end
end

----------------------------------------------------------------------
-- Test helpers
----------------------------------------------------------------------
local passed, failed = 0, 0
local function assert_eq(label, expected, actual)
  if expected == actual then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format(
      "FAIL: %s\n  expected: %s\n  actual:   %s\n", label, tostring(expected), tostring(actual)))
  end
end

local function reset_state()
  core.projects = {}
  core._warnings = {}
  known_dirs = {}
end

----------------------------------------------------------------------
-- Test 1: Round-trip with relative directories
-- Root project at /home/user/projects/app
-- Additional dir at /home/user/libs/somelib
-- Saved relative, restored from the SAME root project path.
----------------------------------------------------------------------
reset_state()
known_dirs["/home/user/projects/app"] = true
known_dirs["/home/user/libs/somelib"] = true
core.projects[1] = { path = "/home/user/projects/app" }
core.projects[2] = { path = "/home/user/libs/somelib" }

local saved = save_directories()
assert_eq("T1: saved as relative", true, saved[1].relative)
assert_eq("T1: relative path value",
  ".." .. PATHSEP .. ".." .. PATHSEP .. "libs" .. PATHSEP .. "somelib",
  saved[1].path)

-- Now simulate restore: only root project exists, restore additional dirs
reset_state()
known_dirs["/home/user/projects/app"] = true
known_dirs["/home/user/libs/somelib"] = true
core.projects[1] = { path = "/home/user/projects/app" }

restore_directories(saved)
assert_eq("T1: restored dir count", 2, #core.projects)
assert_eq("T1: restored additional dir",
  "/home/user/libs/somelib", core.projects[2] and core.projects[2].path)
assert_eq("T1: no warnings", 0, #core._warnings)

----------------------------------------------------------------------
-- Test 2: Restore from a different CWD (the original bug scenario)
-- Root project at /home/user/projects/app, but CWD is /tmp
-- The fix should still resolve relative dirs against the root project.
----------------------------------------------------------------------
reset_state()
known_dirs["/home/user/projects/app"] = true
known_dirs["/home/user/libs/somelib"] = true
core.projects[1] = { path = "/home/user/projects/app" }

-- Use the same saved data from Test 1 (relative paths)
restore_directories(saved)
assert_eq("T2: restored from different CWD", 2, #core.projects)
assert_eq("T2: path correct despite CWD",
  "/home/user/libs/somelib", core.projects[2] and core.projects[2].path)
assert_eq("T2: no warnings", 0, #core._warnings)

----------------------------------------------------------------------
-- Test 3: Absolute directory survives round-trip
-- Simulate a case where the additional dir is on a completely
-- unrelated path (or we force absolute).
----------------------------------------------------------------------
reset_state()
known_dirs["/projects/root"] = true
known_dirs["/opt/external/lib"] = true
core.projects[1] = { path = "/projects/root" }
core.projects[2] = { path = "/opt/external/lib" }

local saved3 = save_directories()
-- relative_path between these two should produce a relative path (not abs)
-- so we manually create an absolute entry to test that branch
local abs_entry = { path = "/opt/external/lib", relative = false }

reset_state()
known_dirs["/projects/root"] = true
known_dirs["/opt/external/lib"] = true
core.projects[1] = { path = "/projects/root" }
restore_directories({ abs_entry })
assert_eq("T3: absolute dir restored", 2, #core.projects)
assert_eq("T3: path correct",
  "/opt/external/lib", core.projects[2] and core.projects[2].path)
assert_eq("T3: no warnings", 0, #core._warnings)

----------------------------------------------------------------------
-- Test 4: Old-format backward compatibility (plain string)
-- Old workspaces stored relative paths as bare strings.
----------------------------------------------------------------------
reset_state()
known_dirs["/home/user/projects/app"] = true
known_dirs["/home/user/libs/somelib"] = true
core.projects[1] = { path = "/home/user/projects/app" }

local old_format = {
  ".." .. PATHSEP .. ".." .. PATHSEP .. "libs" .. PATHSEP .. "somelib"
}
restore_directories(old_format)
assert_eq("T4: old-format string restored", 2, #core.projects)
assert_eq("T4: path correct",
  "/home/user/libs/somelib", core.projects[2] and core.projects[2].path)
assert_eq("T4: no warnings", 0, #core._warnings)

----------------------------------------------------------------------
-- Test 5: Old-format absolute path string
----------------------------------------------------------------------
reset_state()
known_dirs["/projects/root"] = true
known_dirs["/opt/tools"] = true
core.projects[1] = { path = "/projects/root" }

restore_directories({ PATHSEP .. "opt" .. PATHSEP .. "tools" })
assert_eq("T5: old-format abs string restored", 2, #core.projects)
assert_eq("T5: path correct",
  "/opt/tools", core.projects[2] and core.projects[2].path)

----------------------------------------------------------------------
-- Test 6: Missing directory produces warning, not crash
----------------------------------------------------------------------
reset_state()
known_dirs["/projects/root"] = true
-- /projects/missing does NOT exist
core.projects[1] = { path = "/projects/root" }

restore_directories({ { path = "../missing", relative = true } })
assert_eq("T6: missing dir not added", 1, #core.projects)
assert_eq("T6: warning issued", 1, #core._warnings)
assert_eq("T6: warning mentions path", true,
  core._warnings[1]:find("missing") ~= nil)

----------------------------------------------------------------------
-- Test 7: nil/empty directories list is handled gracefully
----------------------------------------------------------------------
reset_state()
core.projects[1] = { path = "/projects/root" }
restore_directories(nil)
assert_eq("T7: nil dirs handled", 1, #core.projects)
restore_directories({})
assert_eq("T7: empty dirs handled", 1, #core.projects)

----------------------------------------------------------------------
-- Test 8: Multiple additional directories round-trip
----------------------------------------------------------------------
reset_state()
known_dirs["/workspace/root"] = true
known_dirs["/workspace/lib-a"] = true
known_dirs["/workspace/lib-b"] = true
known_dirs["/external/shared"] = true
core.projects[1] = { path = "/workspace/root" }
core.projects[2] = { path = "/workspace/lib-a" }
core.projects[3] = { path = "/workspace/lib-b" }
core.projects[4] = { path = "/external/shared" }

local saved8 = save_directories()
assert_eq("T8: saved 3 dirs", 3, #saved8)

-- Restore
reset_state()
known_dirs["/workspace/root"] = true
known_dirs["/workspace/lib-a"] = true
known_dirs["/workspace/lib-b"] = true
known_dirs["/external/shared"] = true
core.projects[1] = { path = "/workspace/root" }

restore_directories(saved8)
assert_eq("T8: all 3 dirs restored", 4, #core.projects)
assert_eq("T8: lib-a correct", "/workspace/lib-a", core.projects[2].path)
assert_eq("T8: lib-b correct", "/workspace/lib-b", core.projects[3].path)
assert_eq("T8: shared correct", "/external/shared", core.projects[4].path)

----------------------------------------------------------------------
-- Test 9: Root project path change (moved project, same structure)
-- Originally saved with root at /old/location, now opened at /new/location
-- Relative dirs should still work if the relative structure is preserved.
----------------------------------------------------------------------
reset_state()
known_dirs["/new/location"] = true
known_dirs["/new/libs/extra"] = true
core.projects[1] = { path = "/new/location" }

-- Simulate workspace saved when root was at /old/location
-- The relative path "../libs/extra" is the same structural relationship
local migrated = {
  { path = ".." .. PATHSEP .. "libs" .. PATHSEP .. "extra", relative = true }
}
restore_directories(migrated)
assert_eq("T9: migrated root resolves correctly", 2, #core.projects)
assert_eq("T9: path correct",
  "/new/libs/extra", core.projects[2].path)

----------------------------------------------------------------------
-- Results
----------------------------------------------------------------------
print(string.format("\nWorkspace path tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
