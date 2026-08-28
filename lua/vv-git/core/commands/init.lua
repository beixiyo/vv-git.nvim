-- git 命令入口：组装按职责拆分的命令模块，并保持原 require 路径

local Context = require('vv-git.core.commands.context')

local command_modules = {
  require('vv-git.core.commands.repository'),
  require('vv-git.core.commands.revision'),
  require('vv-git.core.commands.worktree'),
  require('vv-git.core.commands.commit'),
  require('vv-git.core.commands.remote'),
  require('vv-git.core.commands.file'),
  require('vv-git.core.commands.execute'),
}

local M = {}

---@param deps { controller:table, config:fun():table }
---@return table
function M.new(deps)
  local commands = {}
  local context = Context.new(deps)

  function commands._cancel_command_requests()
    context.cancel_requests()
  end

  function commands._invalidate_command_requests()
    context.invalidate_requests()
  end

  for _, command_module in ipairs(command_modules) do
    for name, command in pairs(command_module.new(context)) do
      assert(commands[name] == nil, 'duplicate vv-git command: ' .. name)
      commands[name] = command
    end
  end

  return commands
end

return M
