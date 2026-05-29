-- panel 交互操作：preview / activate / fold / select / action / layout

local State = require('vv-git.state')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Actions = require('vv-git.left.actions')
local Keymaps = require('vv-git.core.keymaps')

local L = {}

---@param M table
---@return boolean
local function is_narrow(M)
  return vim.o.columns < M._config.single_col_threshold
end

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
  M._reshow_view = State.guarded(function(state)
    local view = state.view
    if not view or not view.node then return end
    local node, section = view.node, view.section
    state.view.path = nil
    state._reshow_restore_win = vim.api.nvim_get_current_win()
    RightView.show(state, node, section, is_narrow(M))
  end)

  M._preview = State.guarded(function(state)
    if not M._config.preview then return end
    if not state.panel or state.panel.win ~= vim.api.nvim_get_current_win() then return end
    local id = Keymaps.id_under_cursor(state)
    if not id or id.section_header then return end
    local node = id.node
    if not node or node.is_dir then return end
    if is_binary(M, state.git_root .. '/' .. node.relpath) then return end
    local view = state.view
    if view and view.path == node.relpath and view.section == id.section
        and view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
      return
    end
    state.cur_path = node.relpath
    state.cur_section = id.section
    RightView.show(state, node, id.section, is_narrow(M))
  end)

  M._activate = State.guarded(function(state, expand_only)
    local id = Keymaps.id_under_cursor(state)
    if not id then return end
    if id.section_header then
      M._toggle_fold()
      return
    end
    local node = id.node
    if not node then return end
    if node.is_dir then
      local fold_key = (id.section or '') .. ':' .. node.relpath
      if not expand_only or state.folds[fold_key] then
        M._toggle_fold()
      end
      return
    end
    local abspath = state.git_root .. '/' .. node.relpath
    if is_binary(M, abspath) then
      require('vv-utils.sys').open_default(abspath)
      return
    end
    state.cur_path = node.relpath
    state.cur_section = id.section
    local view = state.view
    if view and view.path == node.relpath and view.section == id.section
        and view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
      return
    end
    RightView.show(state, node, id.section, is_narrow(M))
  end)

  M._toggle_fold = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id then return end

    -- section 标题行：折叠/展开整个 section
    if id.section_header then
      state.section_folds = state.section_folds or {}
      local sid = id.section_header
      state.section_folds[sid] = not state.section_folds[sid] or nil
      state._section_hint = sid
      LeftRender.render(state)
      return
    end

    if not id.node or not id.node.is_dir then return end
    local fold_key = (id.section or '') .. ':' .. id.node.relpath
    state.folds[fold_key] = not state.folds[fold_key] or nil
    state.cur_path = id.node.relpath
    state.cur_section = id.section
    LeftRender.render(state)
  end)

  M._collapse = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id then return end

    -- section 标题行：直接折叠该 section
    if id.section_header then
      state.section_folds = state.section_folds or {}
      state.section_folds[id.section_header] = true
      state._section_hint = id.section_header
      LeftRender.render(state)
      return
    end

    if not id.node then return end
    local section = id.section or ''
    local fold_key
    if id.node.is_dir and not state.folds[section .. ':' .. id.node.relpath] then
      fold_key = section .. ':' .. id.node.relpath
    else
      local parent = vim.fs.dirname(id.node.relpath)
      if parent == '.' or parent == '' then return end
      fold_key = section .. ':' .. parent
    end
    state.folds[fold_key] = true
    state.cur_path = fold_key:match(':(.+)$') or id.node.relpath
    state.cur_section = id.section
    LeftRender.render(state)
  end)

  M._toggle_select = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id or not id.node or id.node.is_dir or id.section_header then return end
    local key = (id.section or '') .. ':' .. id.node.relpath
    if state.selection[key] then
      state.selection[key] = nil
    else
      state.selection[key] = true
    end

    -- 切换选中不改变行布局：先记下当前行，渲染后按原行恢复。
    -- 不能依赖 render 内部按 cur_path 的恢复——cur_path 仅由 CursorMoved
    -- 的 _preview 同步，且有多处提前 return（preview 关闭 / 二进制 / 焦点不在 panel），
    -- 可能滞后于光标实际行，导致 render 把光标拉到别处（表现为「跳到上面」）。
    local win = state.panel and state.panel.win
    local lnum = (win and vim.api.nvim_win_is_valid(win))
        and vim.api.nvim_win_get_cursor(win)[1] or nil

    -- 同步 cur_path/cur_section，让 render 的恢复逻辑与当前行一致（双保险）
    state.cur_path = id.node.relpath
    state.cur_section = id.section

    LeftRender.render(state)

    if lnum and win and vim.api.nvim_win_is_valid(win) then
      local last = vim.api.nvim_buf_line_count(state.panel.buf)
      local target = (M._config.select_move_down ~= false and lnum < last)
          and lnum + 1
          or lnum
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end
  end)

  M._action = State.guarded(function(state, name)
    if state.compare then return end
    if next(state.selection) then
      local items = {}
      for key in pairs(state.selection) do
        local section, relpath = key:match('^(.-):(.+)$')
        if section and relpath then
          items[#items + 1] = { section = section, relpath = relpath }
        end
      end
      state.selection = {}
      local fn = Actions[name .. '_selection']
      if fn then fn(state, items) end
      return
    end

    local id = Keymaps.id_under_cursor(state)
    if not id then return end
    if id.node then
      state.cur_path = id.node.relpath
      state.cur_section = id.section
    end
    if id.node and id.section and state.panel and state.panel.win
        and vim.api.nvim_win_is_valid(state.panel.win) then
      local lnum = vim.api.nvim_win_get_cursor(state.panel.win)[1]
      state._action_hint = { section = id.section, lnum = lnum }
    end
    local fn = Actions[name]
    if fn then fn(state, id) end
  end)

  -- layout

  local function do_apply_layout(state)
    if not state.git_root then return end
    local view = state.view
    if not view or not view.node then return end
    if view.intrinsic_single then return end

    local want_single = is_narrow(M)
    local is_now_single = (view.mode == 'single')
    if want_single == is_now_single then return end

    RightView.show(state, view.node, view.section, want_single)
  end

  M._apply_layout = State.guarded(function(state)
    if state._resize_timer then pcall(state._resize_timer.close, state._resize_timer) end
    state._resize_timer = vim.uv.new_timer()
    if not state._resize_timer then do_apply_layout(state); return end
    state._resize_timer:start(50, 0, vim.schedule_wrap(function()
      if state._resize_timer then pcall(state._resize_timer.close, state._resize_timer) end
      state._resize_timer = nil
      if State.has() then do_apply_layout(State.get()) end
    end))
  end)
end

return L
