-- commit 命令：校验 staged 状态并管理提交消息窗口生命周期

local State = require('vv-git.state')
local Git = require('vv-git.git')
local Prompt = require('vv-git.left.prompt')

local M = {}

---@param context table
---@return table
function M.new(context)
  local controller = context.controller

  return {
    _commit = State.guarded(function(state)
      if not state.git_root then return end

      local owner_root = state.git_root
      local owner_generation = State.root_generation(state)
      local root = context.cursor_root(state)

      if not root then return end
      local request = context.request_scope:begin({ key = 'commit' })

      Git.has_staged(root, function(has)
        if not context.owns_context(request, state, owner_root, owner_generation) then return end

        local function open_prompt()
          if not context.owns_context(request, state, owner_root, owner_generation) then return end

          local dispose_prompt = Prompt.open({
            git_root = root,
            has_staged = has,
            is_current = function()
              return context.owns_context(request, state, owner_root, owner_generation)
            end,
            on_success = function()
              if not request:finish()
                  or not State.is_current(state)
                  or state.git_root ~= owner_root
                  or State.root_generation(state) ~= owner_generation then
                return
              end
              state._block_hint = root
              controller.refresh()
            end,
            on_cancel = function()
              request:dispose()
            end,
          })

          if type(dispose_prompt) == 'function' then request:set_disposer(dispose_prompt) end
        end

        if has then
          open_prompt()
        else
          vim.ui.select({ 'Commit ALL working tree', 'Cancel' }, {
            prompt = 'No staged changes. Commit all working tree changes instead?',
          }, function(choice)
            if not context.owns_context(request, state, owner_root, owner_generation) then return end
            if choice == 'Commit ALL working tree' then
              open_prompt()
            else
              request:dispose()
            end
          end)
        end
      end)
    end),
  }
end

return M
