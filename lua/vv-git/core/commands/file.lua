-- 文件命令：跳转、复制绝对路径和交给系统打开

local State = require('vv-git.state')
local Keymaps = require('vv-git.core.keymaps')
local Subrepo = require('vv-git.subrepo')
local Editor = require('vv-utils.editor')

local M = {}

---@param context table
---@return table
function M.new(context)
  local controller = context.controller

  local commands = {}

  commands._goto_file = State.guarded(function(state)
    local cur_win = vim.api.nvim_get_current_win()
    local view = state.view
    local abspath, root, relpath, row, col = nil, nil, nil, nil, nil

    if view and view.path and (cur_win == view.a_win or cur_win == view.b_win) then
      if view.node and view.node.is_dir then return end

      root = Subrepo.current_root(state, view.root)
      if not root then return end

      relpath = view.path
      abspath = root .. '/' .. relpath
      if vim.api.nvim_win_is_valid(cur_win) then
        local cursor = vim.api.nvim_win_get_cursor(cur_win)
        row = cursor[1]
        col = cursor[2]
      end
    else
      local id = Keymaps.id_under_cursor(state)
      if not id or not id.node or id.node.is_dir then return end

      root = Subrepo.current_root(state, id.root)
      if not root then return end
      relpath = id.node.relpath
      abspath = root .. '/' .. relpath
    end

    if context.binary(abspath) then
      require('vv-utils.sys').open_default(abspath)
      return
    end

    if type(state._on_goto_file) == 'function' then
      controller._invoke_callback(state._on_goto_file, {
        root = root,
        path = relpath,
        abspath = abspath,
        row = row,
        col = col,
      })
      return
    end

    controller.close()

    local win = vim.api.nvim_get_current_win()
    if vim.wo[win].winfixbuf then
      for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not vim.wo[candidate].winfixbuf and vim.api.nvim_win_get_config(candidate).relative == '' then
          vim.api.nvim_set_current_win(candidate)
          break
        end
      end
    end

    vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
    if row then
      row = math.min(row, vim.api.nvim_buf_line_count(0))
      local target_line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
      pcall(vim.api.nvim_win_set_cursor, 0, { row, math.min(col or 0, #target_line) })
      pcall(vim.cmd, 'normal! zz')
    end
  end)

  commands._yank_abs_path = State.guarded(function(state)
    if not state.git_root then return end

    local cur_win = vim.api.nvim_get_current_win()
    local view = state.view
    local relpath, root

    if view and view.path and (cur_win == view.a_win or cur_win == view.b_win) then
      relpath = view.path
      root = view.root
    else
      local id = Keymaps.id_under_cursor(state)
      if not id or not id.node then return end
      relpath = id.node.relpath
      root = Subrepo.current_root(state, id.root)
      if not root then return end
    end

    root = Subrepo.current_root(state, root)
    if not root then return end
    local abs = vim.fs.normalize(root .. '/' .. relpath)
    Editor.copy_path({ path = abs, title = 'vv-git' })
  end)

  commands._system_open = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id or not id.node then return end

    local root = Subrepo.current_root(state, id.root)
    if not root then return end

    local abspath = vim.fs.normalize(root .. '/' .. id.node.relpath)
    require('vv-utils.sys').open_default(abspath)
  end)

  return commands
end

return M
