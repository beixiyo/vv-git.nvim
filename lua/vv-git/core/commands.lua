-- git 命令操作：commit / push / pull / compare / goto_file / yank_abs_path

local State = require('vv-git.state')
local Git = require('vv-git.git')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Prompt = require('vv-git.left.prompt')
local Editor = require('vv-utils.editor')
local Keymaps = require('vv-git.core.keymaps')

local L = {}

---@param M table
---@param path string
---@return boolean
local function is_binary(M, path)
  local cfg = M._config.binary
  if not cfg or not cfg.intercept then return false end
  local ext = path:match('%.([%w_]+)$')
  return ext and cfg.extensions[ext:lower()] or false
end

---@param M table
function L.attach(M)
  M._compare_pick = State.guarded(function(state)
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

  M._commit_show_pick = State.guarded(function(state)
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

  M._commit = State.guarded(function(state)
    if not state.git_root then return end
    Git.has_staged(state.git_root, function(has)
      local function open_prompt()
        Prompt.open({
          git_root = state.git_root,
          has_staged = has,
          on_success = function() M.refresh() end,
        })
      end
      if has then
        open_prompt()
      else
        vim.ui.select({ 'Commit ALL working tree', 'Cancel' }, {
          prompt = 'No staged changes. Commit all working tree changes instead?',
        }, function(choice)
          if choice == 'Commit ALL working tree' then open_prompt() end
        end)
      end
    end)
  end)

  local git_net = State.guarded(function(state, action)
    if not state.git_root then return end
    local fn = Git[action]
    vim.notify('[vv-git] ' .. action .. '...', vim.log.levels.INFO)
    fn(state.git_root, function(ok, out)
      local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
      local prefix = ok and ('[vv-git] ' .. action .. ' succeeded') or ('[vv-git] ' .. action .. ' failed')
      vim.notify(prefix .. (out and ('\n' .. out) or ''), level)
      if ok then M.refresh() end
    end)
  end)

  function M._push() git_net('push') end
  function M._pull() git_net('pull') end

  M._goto_file = State.guarded(function(state)
    local cur_win = vim.api.nvim_get_current_win()
    local view = state.view
    local abspath, row = nil, nil

    if view and view.path
        and (cur_win == view.a_win or cur_win == view.b_win) then
      abspath = state.git_root .. '/' .. view.path
      if view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
        row = vim.api.nvim_win_get_cursor(view.b_win)[1]
      end
    else
      local id = Keymaps.id_under_cursor(state)
      if not id or not id.node or id.node.is_dir then return end
      abspath = state.git_root .. '/' .. id.node.relpath
    end

    if is_binary(M, abspath) then
      require('vv-utils.sys').open_default(abspath)
      return
    end

    M.close()

    local win = vim.api.nvim_get_current_win()
    if vim.wo[win].winfixbuf then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not vim.wo[w].winfixbuf and vim.api.nvim_win_get_config(w).relative == '' then
          vim.api.nvim_set_current_win(w)
          break
        end
      end
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
    if row then
      pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
      pcall(vim.cmd, 'normal! zz')
    end
  end)

  M._yank_abs_path = State.guarded(function(state)
    if not state.git_root then return end
    local cur_win = vim.api.nvim_get_current_win()
    local view = state.view
    local relpath

    if view and view.path
        and (cur_win == view.a_win or cur_win == view.b_win) then
      relpath = view.path
    else
      local id = Keymaps.id_under_cursor(state)
      if not id or not id.node then return end
      relpath = id.node.relpath
    end

    local abs = vim.fs.normalize(state.git_root .. '/' .. relpath)
    Editor.copy_path({ path = abs, title = 'vv-git' })
  end)
end

return L
