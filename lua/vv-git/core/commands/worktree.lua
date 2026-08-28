-- worktree 命令：在同一 vv-git tab 中原子切换仓库上下文

local State = require('vv-git.state')
local RightView = require('vv-git.right.view')
local Discard = require('vv-git.left.discard')

local M = {}

---@param context table
---@return table
function M.new(context)
  local controller = context.controller

  return {
    _worktree_pick = State.guarded(function(state)
      if not state.git_root then return end
      local Worktree = require('vv-git.worktree')

      Worktree.open_manager(state, function(wt)
        local target = vim.fs.normalize(wt.path)
        if target == state.git_root then
          vim.notify('[vv-git] Already on this worktree', vim.log.levels.INFO)
          return
        end
        if vim.fn.isdirectory(target) == 0 then
          vim.notify('[vv-git] worktree path does not exist (maybe pruned): ' .. target, vim.log.levels.ERROR)
          return
        end

        local target_win
        if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
          target_win = vim.api.nvim_tabpage_list_wins(state.tabpage)[1]
        end

        local changed, change_err = false, 'vv-git tab is no longer valid'
        if target_win and vim.api.nvim_win_is_valid(target_win) then
          changed, change_err = pcall(vim.api.nvim_win_call, target_win, function()
            vim.cmd.tcd(vim.fn.fnameescape(target))
          end)
        end

        if not changed then
          vim.notify('[vv-git] Could not enter worktree: ' .. tostring(change_err), vim.log.levels.ERROR)
          return
        end

        if controller._cancel_root_requests then controller._cancel_root_requests() end
        context.cancel_requests()
        Discard.cancel()

        RightView.close(state)
        require('vv-git.compare').stop(state)

        State.set_root(state, target)
        state.cur_path = nil
        state.selection = {}
        state.folds = {}
        state.section_folds = {}
        state.block_folds = {}

        require('vv-git.loader').reload_index(state)
      end, context.config().worktree)
    end),
  }
end

return M
