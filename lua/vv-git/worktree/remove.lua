-- Confirm and remove one worktree while its manager context is current

local Git = require('vv-git.git')
local Confirm = require('vv-utils.confirm')

local M = {}

local function same_target(expected, current)
  return vim.fs.normalize(current.path) == expected.path
      and current.branch == expected.branch
      and current.head == expected.head
      and (current.detached == true) == expected.detached
end

---@param root string
---@param wt VVGitWorktree
---@param refresh fun()
---@param context {is_active:fun():boolean, begin:fun():vv-utils.async.Request}
function M.run(root, wt, refresh, context)
  if wt.is_main or vim.fs.normalize(wt.path) == vim.fs.normalize(root) then
    vim.notify('[vv-git] The current or main worktree cannot be removed', vim.log.levels.WARN)
    return
  end
  if wt.locked then
    vim.notify('[vv-git] Locked worktrees must be unlocked explicitly before removal', vim.log.levels.WARN)
    return
  end

  local expected = {
    path = vim.fs.normalize(wt.path),
    branch = wt.branch,
    head = wt.head,
    detached = wt.detached == true,
  }
  local request = context.begin()
  local handle

  local function active() return request:is_current() and context.is_active() end
  local function dispose() request:dispose() end
  local function abort(message)
    dispose()
    if message then vim.notify('[vv-git] ' .. message, vim.log.levels.ERROR) end
    refresh()
  end

  local function inspect(done)
    Git.worktree_list(root, function(worktrees, err)
      if not active() then done(nil, 'worktree removal request is no longer current'); return end
      if not worktrees then done(nil, err or 'Could not inspect worktree'); return end
      local target

      for _, current in ipairs(worktrees) do
        if vim.fs.normalize(current.path) == expected.path then target = current; break end
      end

      if not target or not same_target(expected, target) then
        done(nil, 'Worktree changed since it was listed; removal was cancelled')
        return
      end

      if target.is_main or target.locked then
        done(nil, target.locked and 'Locked worktrees cannot be removed' or 'Main worktree cannot be removed')
        return
      end

      Git.worktree_dirty(target.path, function(dirty, dirty_err)
        if not active() then done(nil, 'worktree removal request is no longer current'); return end
        if dirty == nil then done(nil, dirty_err or 'Could not inspect worktree changes'); return end
        done({ target = target, dirty = dirty })
      end)
    end)
  end

  local function remove(snapshot, force, done)
    inspect(function(latest, err)
      if not latest or latest.dirty ~= snapshot.dirty then
        done(false, err or 'Worktree changed', false)
        return
      end

      if not active() then done(false, 'worktree removal request is no longer current', false); return end
      Git.worktree_remove(root, latest.target.path, force and { force = true } or nil, function(ok, remove_err)
        done(ok, remove_err, true)
      end)
    end)
  end

  local function details(snapshot)
    return {
      { label = 'Worktree', value = snapshot.target.path },
      { label = 'Branch', value = snapshot.target.branch or '(detached)' },
      { label = 'HEAD', value = (snapshot.target.head or ''):sub(1, 12) },
    }
  end

  local function confirm_force(snapshot, reason)
    handle = Confirm.open({
      title = 'Force remove worktree?',
      message = reason or 'Git refused to remove the dirty worktree.',
      details = details(snapshot),
      severity = 'danger',
      confirm_label = 'Force remove',
      on_confirm = function()
        remove(snapshot, true, function(ok, err)
          if not active() then return end
          if not ok then abort(err or 'Could not remove worktree'); return end
          if request:finish() then
            vim.notify('[vv-git] Force removed worktree ' .. snapshot.target.path, vim.log.levels.WARN)
            refresh()
          end
        end)
      end,
      on_cancel = dispose,
    })
  end

  local function confirm_remove(snapshot)
    handle = Confirm.open({
      title = 'Remove worktree?',
      message = snapshot.dirty
          and 'This worktree has uncommitted changes. A normal removal will be attempted first.'
          or 'Remove this worktree?',
      details = details(snapshot),
      severity = snapshot.dirty and 'danger' or 'warn',
      confirm_label = 'Remove',
      on_confirm = function()
        remove(snapshot, false, function(ok, err, attempted)
          if not active() then return end
          if ok then
            if request:finish() then
              vim.notify('[vv-git] Removed worktree ' .. snapshot.target.path, vim.log.levels.INFO)
              refresh()
            end
          elseif snapshot.dirty and attempted then
            confirm_force(snapshot, err)
          else
            abort(err or 'Could not remove worktree')
          end
        end)
      end,
      on_cancel = dispose,
    })
  end

  request:set_disposer(function() if handle then handle.close() end end)
  inspect(function(snapshot, err)
    if not active() then dispose(); return end
    if not snapshot then abort(err); return end
    confirm_remove(snapshot)
  end)
end

return M
