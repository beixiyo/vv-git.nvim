-- panel 操作共享上下文：统一注入依赖与运行时配置

local State = require('vv-git.state')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Actions = require('vv-git.left.actions')
local Keymaps = require('vv-git.core.keymaps')
local Subrepo = require('vv-git.subrepo')
local Tree = require('vv-git.tree')
local FilePolicy = require('vv-git.file_policy')
local Navigation = require('vv-git.core.navigation')

local M = {}

---@param deps { controller:table, config:fun():table }
---@return table
function M.new(deps)
  local context = {
    State = State,
    LeftRender = LeftRender,
    RightView = RightView,
    Actions = Actions,
    Keymaps = Keymaps,
    Subrepo = Subrepo,
    Tree = Tree,
    Navigation = Navigation,
    controller = deps.controller,
  }

  function context.config() return deps.config() end
  function context.narrow() return vim.o.columns < context.config().single_col_threshold end
  function context.binary(path) return FilePolicy.is_binary(path, context.config().binary) end

  return context
end

return M
