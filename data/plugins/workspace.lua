-- mod-version:4
local core = require "core"
local common = require "core.common"
local DocView = require "core.docview"
local LogView = require "core.logview"
local storage = require "core.storage"

local STORAGE_MODULE = "ws"

local function workspace_keys_for(project_dir)
  local basename = common.basename(project_dir)
  return coroutine.wrap(function()
    for _, key in ipairs(storage.keys(STORAGE_MODULE) or {}) do
      if key:sub(1, #basename) == basename then
        local id = tonumber(key:sub(#basename + 1):match("^-(%d+)$"))
        if id then
          coroutine.yield(key, id)
        end
      end
    end
  end)
end


local function consume_workspace(project_dir)
  for key, id in workspace_keys_for(project_dir) do
    local workspace = storage.load(STORAGE_MODULE, key)
    if workspace and workspace.path == project_dir then
      storage.clear(STORAGE_MODULE, key)
      return workspace
    end
  end
end


local function has_no_locked_children(node)
  if node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end


local function get_unlocked_root(node)
  if node.type == "leaf" then
    return not node.locked and node
  end
  if has_no_locked_children(node) then
    return node
  end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end


local function save_view(view)
  local mt = getmetatable(view)
  if mt == DocView then
    return {
      type = "doc",
      active = (core.active_view == view),
      filename = view.doc.filename,
      selection = { view.doc:get_selection() },
      scroll = { x = view.scroll.to.x, y = view.scroll.to.y },
      crlf = view.doc.crlf,
      text = view.doc.new_file and view.doc:get_text(1, 1, math.huge, math.huge)
    }
  end
  if mt == LogView then return end
  for name, mod in pairs(package.loaded) do
    if mod == mt then
      return {
        type = "view",
        active = (core.active_view == view),
        module = name,
        scroll = { x = view.scroll.to.x, y = view.scroll.to.y, to = { x = view.scroll.to.x, y = view.scroll.to.y } },
      }
    end
  end
end


local function load_view(t)
  if t.type == "doc" then
    local dv
    if not t.filename then
      -- document not associated to a file
      dv = DocView(core.open_doc())
    else
      -- we have a filename, try to read the file
      local ok, doc = pcall(core.open_doc, t.filename)
      if ok then
        dv = DocView(doc)
      end
    end
    if dv and dv.doc then
      if dv.doc.new_file and t.text then
        dv.doc:insert(1, 1, t.text)
        dv.doc.crlf = t.crlf
      end
      dv.doc:set_selection(table.unpack(t.selection))
      dv.last_line1, dv.last_col1, dv.last_line2, dv.last_col2 = dv.doc:get_selection()
      dv.scroll.x, dv.scroll.to.x = t.scroll.x, t.scroll.x
      dv.scroll.y, dv.scroll.to.y = t.scroll.y, t.scroll.y
    end
    return dv
  end
  return require(t.module)()
end


local function save_node(node)
  local res = {}
  res.type = node.type
  if node.type == "leaf" then
    res.views = {}
    for _, view in ipairs(node.views) do
      local t = save_view(view)
      if t then
        table.insert(res.views, t)
        if node.active_view == view then
          res.active_view = #res.views
        end
      end
    end
  else
    res.divider = node.divider
    res.a = save_node(node.a)
    res.b = save_node(node.b)
  end
  return res
end


local function load_node(node, t)
  if t.type == "leaf" then
    local res
    local active_view
    for i, v in ipairs(t.views) do
      local view = load_view(v)
      if view then
        if v.active then res = view end
        node:add_view(view)
        if t.active_view == i then
          active_view = view
        end
        if not view:is(DocView) then
          view.scroll = v.scroll
        end
      end
    end
    if active_view then
      node:set_active_view(active_view)
    end
    return res
  else
    node:split(t.type == "hsplit" and "right" or "down")
    node.divider = t.divider
    local res1 = load_node(node.a, t.a)
    local res2 = load_node(node.b, t.b)
    return res1 or res2
  end
end


-- Additional (non-root) project directories are stored relative to the root
-- project's path. Keeping them relative makes a saved workspace portable when
-- the whole project tree is moved, as long as the extra directories keep the
-- same position relative to the root project.
local function save_directories(base_path)
  local dir_list = {}
  for i = 2, #core.projects do
    dir_list[#dir_list + 1] = common.relative_path(base_path, core.projects[i].path)
  end
  return dir_list
end


-- Turn a stored directory entry back into an absolute path.
--
-- Entries written by save_directories are relative to the root project's path,
-- so they must be resolved against that same base. Resolving them against the
-- current working directory (as the previous implementation did via
-- system.absolute_path) meant a workspace restored from a different launch
-- directory would relocate or lose its extra projects.
--
-- Absolute entries are kept as-is (only normalized). These occur with older
-- workspace data and, on Windows, when an extra project lives on a different
-- drive than the root project (see common.relative_path).
local function resolve_project_dir(base_path, dir_name)
  if common.is_absolute_path(dir_name) then
    return common.normalize_path(dir_name)
  end
  return common.normalize_path(base_path .. PATHSEP .. dir_name)
end


-- Restore the additional project directories, resolving each against the root
-- project's path. Failures are isolated per-directory so one bad entry cannot
-- drop the rest, and every problem is reported instead of being swallowed.
local function restore_directories(base_path, directories)
  for _, dir_name in ipairs(directories or {}) do
    local ok_resolve, abs_path = pcall(resolve_project_dir, base_path, dir_name)
    if not ok_resolve or not abs_path then
      core.error("[workspace] could not resolve project directory %q", tostring(dir_name))
    else
      local info = system.get_file_info(abs_path)
      if not info or info.type ~= "dir" then
        core.warn("[workspace] skipping missing project directory %q", abs_path)
      else
        local ok, err = pcall(core.add_project, abs_path)
        if not ok then
          core.error("[workspace] failed to restore project directory %q: %s", abs_path, tostring(err))
        end
      end
    end
  end
end


local function save_workspace()
  local project_dir = common.basename(core.root_project().path)
  local id_list = {}
  for filename, id in workspace_keys_for(project_dir) do
    id_list[id] = true
  end
  local id = 1
  while id_list[id] do
    id = id + 1
  end
  local root = get_unlocked_root(core.root_view.root_node)
  local base_path = core.root_project().path
  storage.save(STORAGE_MODULE, project_dir .. "-" .. id, { path = base_path, documents = save_node(root), directories = save_directories(base_path) })
end


local function load_workspace()
  local base_path = core.root_project().path
  local workspace = consume_workspace(base_path)
  if workspace then
    local root = get_unlocked_root(core.root_view.root_node)
    local active_view = load_node(root, workspace.documents)
    if active_view then
      core.set_active_view(active_view)
    end
    restore_directories(base_path, workspace.directories)
  end
end


local run = core.run

function core.run(...)
  if #core.docs == 0 then
    core.try(load_workspace)

    local set_project = core.set_project
    function core.set_project(project)
      core.try(save_workspace)
      local project = set_project(project)
      core.try(load_workspace)
      return project
    end
    local exit = core.exit
    function core.exit(quit_fn, force)
      if force then core.try(save_workspace) end
      exit(quit_fn, force)
    end
    
  end

  core.run = run
  return core.run(...)
end


-- Exposed for tests/external use. The plugin installs itself by patching
-- core.run above; the returned table only carries the pure directory helpers
-- so the multi-project path logic can be exercised in isolation.
return {
  save_directories = save_directories,
  resolve_project_dir = resolve_project_dir,
  restore_directories = restore_directories,
}
