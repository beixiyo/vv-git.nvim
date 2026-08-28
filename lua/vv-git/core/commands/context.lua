-- 命令共享上下文：统一请求取消、state 所有权检查和仓库路由

local State = require('vv-git.state')
local Prompt = require('vv-git.left.prompt')
local Async = require('vv-utils.async')
local Keymaps = require('vv-git.core.keymaps')
local FilePolicy = require('vv-git.file_policy')
local Subrepo = require('vv-git.subrepo')

local M = {}

---@param deps { controller:table, config:fun():table }
---@return table
function M.new(deps)
  local context = {
    controller = deps.controller,
    request_scope = Async.scope({ cancel_previous = true }),
  }

  function context.config() return deps.config() end

  ---@param path string
  ---@return boolean
  function context.binary(path)
    return FilePolicy.is_binary(path, context.config().binary)
  end

  ---@param state table
  ---@return string? root
  function context.cursor_root(state)
    local id = Keymaps.id_under_cursor(state)
    return Subrepo.current_root(state, id and id.root)
  end

  ---@param state table
  ---@return boolean
  local function panel_is_alive(state)
    if not state.panel then return true end
    return state.panel.buf
        and vim.api.nvim_buf_is_valid(state.panel.buf)
        and state.panel.win
        and vim.api.nvim_win_is_valid(state.panel.win)
  end

  ---@param state table
  ---@param owner_root string
  ---@param owner_generation integer
  ---@return boolean
  function context.owns_state(state, owner_root, owner_generation)
    return State.is_current(state)
        and not state._closing
        and state.git_root == owner_root
        and State.root_generation(state) == owner_generation
        and panel_is_alive(state)
  end

  ---@param request vv-utils.async.Request
  ---@param state table
  ---@param owner_root string
  ---@param owner_generation integer
  ---@return boolean
  function context.owns_context(request, state, owner_root, owner_generation)
    return request:is_current() and context.owns_state(state, owner_root, owner_generation)
  end

  ---@return fun(cancel:fun()?) add, fun() cancel_all
  function context.new_cancel_bag()
    local cancelled = false
    local cancels = {}

    local function add(cancel)
      if type(cancel) ~= 'function' then return end
      if cancelled then
        pcall(cancel)
      else
        cancels[#cancels + 1] = cancel
      end
    end

    local function cancel_all()
      if cancelled then return end
      cancelled = true
      for _, cancel in ipairs(cancels) do pcall(cancel) end
      cancels = {}
    end

    return add, cancel_all
  end

  function context.cancel_requests()
    context.request_scope:cancel()
    Prompt.close()
  end

  function context.invalidate_requests()
    context.request_scope:invalidate()
    Prompt.close()
  end

  return context
end

return M
