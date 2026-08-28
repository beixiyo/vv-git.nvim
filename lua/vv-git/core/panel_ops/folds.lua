-- panel 折叠与文件选择

local State = require('vv-git.state')

local L = {}

---@param context table
---@return table
function L.new(context)
  local M = {}
  local Subrepo = context.Subrepo
  local LeftRender = context.LeftRender
  local Keymaps = context.Keymaps

  M._toggle_fold = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id then return end

    -- 仓库块（根仓库 / 子仓库）标题行：折叠/展开整个块
    if id.block_header then
      state.block_folds = state.block_folds or {}
      local r = id.block_header
      state.block_folds[r] = not state.block_folds[r] or nil
      state._block_hint = r
      LeftRender.render(state)
      return
    end

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
    local fold_key = Subrepo.sel_key(id.section or '', id.node.relpath)
    state.folds[fold_key] = not state.folds[fold_key] or nil
    state.cur_path = id.node.relpath
    state.cur_section = id.section
    LeftRender.render(state)
  end)

  -- 焦点保持在左侧 panel，折叠动作在右侧当前 diff 窗口上下文执行
  M._toggle_diff_folds = State.guarded(function(state)
    context.RightView.toggle_all_folds(state)
  end)

  M._collapse = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id then return end

    -- 仓库块（根仓库 / 子仓库）标题行：直接折叠整个块
    if id.block_header then
      state.block_folds = state.block_folds or {}
      state.block_folds[id.block_header] = true
      state._block_hint = id.block_header
      LeftRender.render(state)
      return
    end

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
    if id.node.is_dir and not state.folds[Subrepo.sel_key(section, id.node.relpath)] then
      fold_key = Subrepo.sel_key(section, id.node.relpath)
    else
      local parent = vim.fs.dirname(id.node.relpath)
      if parent == '.' or parent == '' then
        -- 最外层文件/已折叠的最外层目录（无父目录可收）→ 继续往外折叠整个所属 section
        -- （Staged Changes / Changes / Merge Conflicts），光标归到该 section 标题行
        if section ~= '' then
          state.section_folds = state.section_folds or {}
          state.section_folds[section] = true
          state._section_hint = section
          LeftRender.render(state)
        end
        return
      end
      fold_key = Subrepo.sel_key(section, parent)
    end
    state.folds[fold_key] = true
    state.cur_path = (select(2, Subrepo.split_key(fold_key))) or id.node.relpath
    state.cur_section = id.section
    LeftRender.render(state)
  end)

  M._toggle_select = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id or not id.node or id.node.is_dir or id.section_header then return end
    local key = Subrepo.sel_key(id.section or '', id.node.relpath)
    if state.selection[key] then
      state.selection[key] = nil
    else
      state.selection[key] = true
    end

    -- 切换选中不改变行布局：先记下当前行，渲染后按原行恢复
    -- 不能依赖 render 内部按 cur_path 的恢复——cur_path 仅由 CursorMoved
    -- 的 _preview 同步，且有多处提前 return（preview 关闭 / 二进制 / 焦点不在 panel），
    -- 可能滞后于光标实际行，导致 render 把光标拉到别处（表现为「跳到上面」）
    local win = state.panel and state.panel.win
    local lnum = (win and vim.api.nvim_win_is_valid(win))
        and vim.api.nvim_win_get_cursor(win)[1] or nil

    -- 同步 cur_path/cur_section，让 render 的恢复逻辑与当前行一致（双保险）
    state.cur_path = id.node.relpath
    state.cur_section = id.section

    LeftRender.render(state)

    if lnum and win and vim.api.nvim_win_is_valid(win) then
      local last = vim.api.nvim_buf_line_count(state.panel.buf)
      local target = (context.config().select_move_down ~= false and lnum < last)
          and lnum + 1
          or lnum
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end
  end)

  return M
end

return L
