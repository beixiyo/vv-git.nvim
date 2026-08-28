-- revision 命令：比较 refs、展示 commit 和退出比较模式

local State = require('vv-git.state')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')

local M = {}

---@param context table
---@return table
function M.new(context)
  local commands = {}
  local controller = context.controller

  commands._compare_pick = State.guarded(function(state)
    if not state.git_root then return end
    local Compare = require('vv-git.compare')
    Compare.open_picker(state, function(hash, short, label)
      Compare.start(state, hash, short, label, function()
        state.selection = {}
        RightView.close(state)
        LeftRender.render(state)
      end)
    end)
  end)

  commands._compare_ref = State.guarded(function(_, ref)
    commands._compare_refs(ref, 'HEAD')
  end)

  commands._compare_refs = State.guarded(function(state, from_ref, to_ref, on_ready, on_error)
    if not state.git_root or not from_ref or from_ref == '' or not to_ref or to_ref == '' then return end
    local Compare = require('vv-git.compare')
    Compare.start_refs(state, from_ref, to_ref, from_ref:sub(1, 7), from_ref .. '..' .. to_ref, function()
      state.selection = {}
      RightView.close(state)
      LeftRender.render(state)
      controller._invoke_callback(on_ready, controller._context(state))
    end, function(message)
      controller._invoke_callback(on_error, message)
    end)
  end)

  commands._compare_stop = State.guarded(function(state)
    if not state.compare then return false end
    require('vv-git.compare').stop(state)
    state.selection = {}
    RightView.close(state)
    LeftRender.render(state)
    return true
  end)

  commands._commit_show_pick = State.guarded(function(state)
    if not state.git_root then return end
    local Compare = require('vv-git.compare')
    Compare.open_picker(state, function(hash, short, label)
      Compare.start_commit(state, hash, short, label, function()
        state.selection = {}
        RightView.close(state)
        LeftRender.render(state)
      end)
    end)
  end)

  commands._commit_show = State.guarded(function(state, hash, on_ready, on_error)
    if not state.git_root or not hash or hash == '' then return end
    local Compare = require('vv-git.compare')
    local short = hash:sub(1, 7)
    local subject = vim.fn.system({ 'git', '-C', state.git_root, 'log', '-1', '--format=%s', hash })
    subject = vim.v.shell_error == 0 and vim.trim(subject) or ''
    local label = subject ~= '' and (short .. '  ' .. subject) or short
    Compare.start_commit(state, hash, short, label, function()
      state.selection = {}
      RightView.close(state)
      LeftRender.render(state)
      controller._invoke_callback(on_ready, controller._context(state))
    end, function(message)
      controller._invoke_callback(on_error, message)
    end)
  end)

  return commands
end

return M
