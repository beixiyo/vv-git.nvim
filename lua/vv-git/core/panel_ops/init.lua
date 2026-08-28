-- panel 交互操作入口；实现按职责位于 core/panel_ops/ 子模块

local Context = require('vv-git.core.panel_ops.context')
local Layout = require('vv-git.core.panel_ops.layout')
local Preview = require('vv-git.core.panel_ops.preview')
local Folds = require('vv-git.core.panel_ops.folds')
local Actions = require('vv-git.core.panel_ops.actions')

local L = {}

---@param deps { controller:table, config:fun():table }
---@return table
function L.new(deps)
  local context = Context.new(deps)
  local folds = Folds.new(context)
  context.toggle_fold = folds._toggle_fold

  local operations = {}
  local modules = {
    Layout.new(context),
    Preview.new(context),
    folds,
    Actions.new(context, context.toggle_fold),
  }

  for _, module in ipairs(modules) do
    for name, operation in pairs(module) do
      operations[name] = operation
    end
  end

  operations.apply_diff_ratio = Layout.apply_diff_ratio
  return operations
end

L.apply_diff_ratio = Layout.apply_diff_ratio

return L
