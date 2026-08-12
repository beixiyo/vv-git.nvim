-- Create a worktree while the manager still owns the request

local Git = require('vv-git.git')

local M = {}

local function input(opts, current, done, cancel)
  vim.ui.input(opts, function(value)
    if not current() then return end
    value = value and vim.trim(value) or ''
    if value ~= '' then done(value) else cancel() end
  end)
end

local function default_path(root, branch, config)
  local resolver = config and config.path
  if type(resolver) == 'function' then
    local ok, path = pcall(resolver, root, branch)
    if ok and type(path) == 'string' and path ~= '' then return vim.fs.normalize(path) end
    vim.notify('[vv-git] worktree.path must return a non-empty path; using the default', vim.log.levels.WARN)
  end
  return vim.fs.joinpath(root, '.worktrees', branch:match('/([^/]+)$') or branch)
end

---@param root string
---@param layout_root string
---@param refresh fun()
---@param config table?
---@param context {is_active:fun():boolean, begin:fun():vv-utils.async.Request}
function M.run(root, layout_root, refresh, config, context)
  local request = context.begin()
  local function current() return request:is_current() and context.is_active() end
  local function cancel() request:dispose() end

  local function add(path, base, branch)
    if not current() then return end
    Git.worktree_add(root, { path = vim.fs.normalize(path), base = base, branch = branch }, function(ok, err)
      if not current() then return end
      if not ok then
        vim.notify('[vv-git] ' .. (err or 'Could not create worktree'), vim.log.levels.ERROR)
        cancel()
        return
      end
      if request:finish() then
        vim.notify('[vv-git] Created worktree at ' .. path, vim.log.levels.INFO)
        refresh()
      end
    end)
  end

  vim.ui.select({ 'Existing branch', 'New branch' }, { prompt = 'Create worktree:' }, function(kind)
    if not current() then return end
    if not kind then cancel(); return end
    Git.branches(root, function(branches, err)
      if not current() then return end
      if not branches then
        vim.notify('[vv-git] ' .. (err or 'No branches found'), vim.log.levels.ERROR)
        cancel()
        return
      end

      if kind == 'Existing branch' then
        Git.worktree_list(root, function(worktrees, list_err)
          if not current() then return end
          if not worktrees then
            vim.notify('[vv-git] ' .. (list_err or 'Could not list worktrees'), vim.log.levels.ERROR)
            cancel()
            return
          end
          local occupied = {}
          for _, wt in ipairs(worktrees) do if wt.branch then occupied[wt.branch] = true end end
          local available = vim.tbl_filter(function(branch) return not occupied[branch] end, branches)
          if #available == 0 then
            vim.notify('[vv-git] Every local branch already has a worktree', vim.log.levels.INFO)
            cancel()
            return
          end
          vim.ui.select(available, { prompt = 'Branch for new worktree:' }, function(branch)
            if not current() then return end
            if not branch then cancel(); return end
            input({ prompt = 'Worktree path: ', default = default_path(layout_root, branch, config), completion = 'dir' }, current,
              function(path) add(path, branch) end, cancel)
          end)
        end)
        return
      end

      input({ prompt = 'New branch: ' }, current, function(branch)
        vim.ui.select(branches, { prompt = 'Base ref:' }, function(base)
          if not current() then return end
          if not base then cancel(); return end
          input({ prompt = 'Worktree path: ', default = default_path(layout_root, branch, config), completion = 'dir' }, current,
            function(path) add(path, base, branch) end, cancel)
        end)
      end, cancel)
    end, kind == 'Existing branch' and { local_only = true } or nil)
  end)
end

return M
