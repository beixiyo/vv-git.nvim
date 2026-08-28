-- 执行命令：解析光标文件的运行计划，并在确认后打开终端

local State = require('vv-git.state')
local Keymaps = require('vv-git.core.keymaps')
local Subrepo = require('vv-git.subrepo')

local M = {}

---@param context table
---@return table
function M.new(context)
  return {
    _execute = State.guarded(function(state)
      local id = Keymaps.id_under_cursor(state)
      if not id or not id.node or id.node.is_dir then return end

      local root = Subrepo.current_root(state, id.root)
      if not root then return end

      local abspath = vim.fs.normalize(root .. '/' .. id.node.relpath)
      local plan, err = require('vv-utils.exec').resolve(abspath)

      if not plan then
        vim.notify('vv-git: ' .. (err or ('cannot run ' .. abspath)), vim.log.levels.WARN)
        return
      end

      local owner_root = state.git_root
      local owner_generation = State.root_generation(state)
      local request = context.request_scope:begin({ key = 'execute' })
      local confirm_handle

      local function current()
        return context.owns_context(request, state, owner_root, owner_generation)
            and Subrepo.current_root(state, root) == root
      end

      local function cancel()
        request:dispose()
      end

      confirm_handle = require('vv-utils.exec').confirm.open({
        path = abspath,
        cwd = plan.cwd or vim.fs.dirname(abspath),
        cmd = plan.cmd,
        target = plan.target,
        notify_prefix = 'vv-git',

        on_confirm = function()
          if not current() then
            request:dispose()
            return
          end
          if not request:finish() then return end
          vim.cmd('botright 15new')
          vim.fn.jobstart(plan.cmd, { term = true, cwd = plan.cwd or vim.fs.dirname(abspath) })
          vim.cmd('startinsert')
        end,
        on_cancel = cancel,
      })

      if type(confirm_handle) == 'table' and type(confirm_handle.close) == 'function' then
        request:set_disposer(confirm_handle.close)
      end
    end),
  }
end

return M
