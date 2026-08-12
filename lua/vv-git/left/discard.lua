-- Discard confirmation and irreversible operation lifecycle

local Git = require('vv-git.git')
local State = require('vv-git.state')
local Async = require('vv-utils.async')
local Confirm = require('vv-utils.confirm')
local Subrepo = require('vv-git.subrepo')

local M = {}
local scope = Async.scope({ cancel_previous = true })

---@param state table
---@param groups {root:string, tracked:string[], untracked:string[]}[]
---@param opts {title:string, message:any, severity:'warn'|'danger', after:fun(), on_cancel?:fun(), owner_root?:string, owner_generation?:integer}
function M.confirm(state, groups, opts)
  local owner_root = opts.owner_root or state.git_root
  local owner_generation = opts.owner_generation or State.root_generation(state)
  local request = scope:begin({ key = 'discard' })
  local handle

  local function groups_are_current()
    for _, group in ipairs(groups) do
      if Subrepo.current_root(state, group.root) ~= group.root then return false end
    end
    return true
  end

  local function current()
    local panel = state.panel
    return request:is_current()
        and State.is_current(state)
        and not state._closing
        and state.git_root == owner_root
        and State.root_generation(state) == owner_generation
        and groups_are_current()
        and (not panel or (panel.buf and vim.api.nvim_buf_is_valid(panel.buf)
          and panel.win and vim.api.nvim_win_is_valid(panel.win)))
  end

  local function dispose()
    state._action_hint = nil
    request:dispose()
  end

  handle = Confirm.open({
    title = opts.title,
    message = opts.message,
    severity = opts.severity,
    confirm_label = 'Discard',
    on_confirm = function()
      if not current() then dispose(); return end
      local operations = {}
      for _, group in ipairs(groups) do
        if #group.tracked > 0 then
          operations[#operations + 1] = { root = group.root, paths = group.tracked, apply = Git.discard }
        end
        if #group.untracked > 0 then
          operations[#operations + 1] = {
            root = group.root,
            paths = group.untracked,
            apply = Git.discard_untracked,
          }
        end
      end

      local function run(index, first_error)
        if not current() then dispose(); return end
        local operation = operations[index]
        if not operation then
          if first_error then
            vim.notify('[vv-git] discard failed: ' .. tostring(first_error), vim.log.levels.ERROR)
          end
          if request:finish() then opts.after() end
          return
        end
        operation.apply(operation.root, operation.paths, function(ok, err)
          run(index + 1, first_error or (not ok and (err or 'operation failed')) or nil)
        end)
      end

      run(1)
    end,
    on_cancel = function()
      dispose()
      if opts.on_cancel then opts.on_cancel() end
    end,
  })

  if type(handle) == 'table' and type(handle.close) == 'function' then
    request:set_disposer(function()
      state._action_hint = nil
      handle.close()
    end)
  else
    request:dispose()
  end
end

function M.cancel()
  scope:cancel()
end

return M
