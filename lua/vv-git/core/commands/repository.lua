-- 仓库命令：把初始化空状态转换为正常 Git 面板

local State = require('vv-git.state')
local Git = require('vv-git.git')
local Loader = require('vv-git.loader')
local LeftRender = require('vv-git.left.render')
local Keymaps = require('vv-git.core.keymaps')
local UGit = require('vv-utils.git')

local M = {}

---@param context table
---@return table
function M.new(context)
  local controller = context.controller
  local function activate_repository(state, root, after_reload)
    state.init_root = nil
    state.parent_root = nil
    state.parent_ignored = nil
    State.set_root(state, root)
    state.cur_path = nil
    state.selection = {}
    state.folds = {}
    state.section_folds = {}
    state.block_folds = {}
    state.subrepos = {}
    state.index = nil
    state.repo_info = nil
    state.tree = nil
    Keymaps.set_repository_setup(state, controller)
    LeftRender.render(state)
    Loader.reload_index(state, after_reload)
  end

  return {
    _init_repository = State.guarded(function(state)
      local init_root = state.init_root
      if not init_root or state._initializing_repository then return false end

      state._initializing_repository = true
      LeftRender.render(state)

      Git.init(init_root, function(ok, err)
        if not State.is_current(state) or state._closing or state.init_root ~= init_root then return end

        state._initializing_repository = nil
        if not ok then
          vim.notify('[vv-git] git init failed\n' .. (err or 'unknown error'), vim.log.levels.ERROR)
          LeftRender.render(state)
          return
        end

        local root = UGit.root(init_root)
        if not root then
          vim.notify('[vv-git] git init succeeded but repository root could not be resolved', vim.log.levels.ERROR)
          LeftRender.render(state)
          return
        end

        activate_repository(state, root, function()
          vim.notify('[vv-git] Initialized Git repository: ' .. root, vim.log.levels.INFO)
        end)
      end)

      return true
    end),

    _open_parent_repository = State.guarded(function(state)
      local parent_root = state.parent_root
      if not parent_root then return false end

      local root = UGit.root(parent_root)
      if not root then
        vim.notify('[vv-git] Parent Git repository is no longer available: ' .. parent_root, vim.log.levels.ERROR)
        return false
      end

      if controller._remember_parent_repository then
        controller._remember_parent_repository(state.init_root, root)
      end
      activate_repository(state, root)
      return true
    end),
  }
end

return M
