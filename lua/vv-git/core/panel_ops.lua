-- panel 交互操作：preview / activate / fold / select / action / layout

local State = require('vv-git.state')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Actions = require('vv-git.left.actions')
local Keymaps = require('vv-git.core.keymaps')
local Subrepo = require('vv-git.subrepo')
local Tree = require('vv-git.tree')

local L = {}

local function ensure_unique_panel(state)
  local panel = state.panel
  if not panel or not panel.buf or not state.tabpage then return end

  local keeper, closed = require('vv-utils.ui_window').ensure_unique_buffer_window(
    state.tabpage,
    panel.buf,
    panel.win
  )
  panel.win = keeper

  local view = state.view
  if not view or #closed == 0 then return end

  for _, win in ipairs(closed) do
    if panel.main_win == win then panel.main_win = nil end
    for _, key in ipairs({ 'a_win', 'b_win', 'c_win' }) do
      if view[key] == win then view[key] = nil end
    end
  end
end

---@param state table
---@param ratio number[]?
function L.apply_diff_ratio(state, ratio)
  local view = state.view
  if not view or view.mode ~= 'diff2' then return end
  if not view.a_win or not vim.api.nvim_win_is_valid(view.a_win) then return end
  if not view.b_win or not vim.api.nvim_win_is_valid(view.b_win) then return end
  if not ratio or not ratio[1] or not ratio[2] then return end

  local sum = ratio[1] + ratio[2]
  if sum <= 0 then return end

  local total = vim.api.nvim_win_get_width(view.a_win)
      + vim.api.nvim_win_get_width(view.b_win)
  vim.api.nvim_win_set_width(view.a_win, math.floor(total * ratio[1] / sum))
end

---@param deps { controller:table, config:fun():table }
---@return table
function L.new(deps)
  local M = {}
  local function config() return deps.config() end
  local function narrow() return vim.o.columns < config().single_col_threshold end
  local function binary(path)
    local cfg = config().binary
    if not cfg or not cfg.intercept then return false end
    local ext = path:match('%.([%w_]+)$')
    return ext and cfg.extensions[ext:lower()] or false
  end
  M.apply_diff_ratio = L.apply_diff_ratio

-- 动作（stage/unstage/discard/accept）触发渲染后，把光标落到「下一个文件」
-- 仅靠旧的绝对行号 hint.lnum 不可靠：stage 会把文件移到上方的 Staged section，
-- 该 section 增长把下方 Changes 整体顶下去，旧行号便指向了被暂存文件「上方」的条目，
-- 表现为光标无规律上跳。改为在动作前记下同 section 内**下一个 / 上一个文件**的 relpath，
-- 渲染后按 relpath 定位，自然跳过目录行
---@param state table
---@param id table  当前光标 id（含 section / node）
---@param lnum integer 当前行号
---@return string? next_path 下一个文件 relpath
---@return string? prev_path 上一个文件 relpath（next 不存在时回退）
local function action_neighbor_leaves(state, id, lnum)
  local id_by_line = state.panel and state.panel.id_by_line or {}
  local section = id.section
  local acted = id.node
  if not section or not acted then return nil, nil end

  -- 操作目录时其下 leaf 都会离开本 section，捕获的「下一个文件」必须排除整棵子树
  local function under_acted(node)
    if acted.is_dir then
      return node.relpath == acted.relpath
          or node.relpath:sub(1, #acted.relpath + 1) == acted.relpath .. '/'
    end
    return node.relpath == acted.relpath
  end

  local lnums = {}
  for l in pairs(id_by_line) do lnums[#lnums + 1] = l end
  table.sort(lnums)

  local next_path, prev_path
  for _, l in ipairs(lnums) do
    local e = id_by_line[l]
    if e and e.section == section and e.node and not e.node.is_dir and not under_acted(e.node) then
      if l > lnum then
        if not next_path then next_path = e.node.relpath end
      elseif l < lnum then
        prev_path = e.node.relpath  -- 升序遍历，持续覆盖 → 取最接近 lnum 的上一个文件
      end
    end
  end

  return next_path, prev_path
end

  M._reshow_view = State.guarded(function(state)
    local view = state.view
    if not view or not view.node then return end
    local node, section = view.node, view.section
    state.view.path = nil
    state._reshow_restore_win = vim.api.nvim_get_current_win()
    RightView.show(state, node, section, narrow(), view.root)
  end)

  M._preview = State.guarded(function(state)
    if not config().preview then return end
    if not state.panel or state.panel.win ~= vim.api.nvim_get_current_win() then return end
    local id = Keymaps.id_under_cursor(state)
    if not id or id.section_header then return end
    local node = id.node
    if not node or node.is_dir then return end
    local root = id.root or state.git_root
    if binary(root .. '/' .. node.relpath) then return end
    local view = state.view
    if view and view.path == node.relpath and view.section == id.base and view.root == root
        and view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
      return
    end
    state.cur_path = node.relpath
    state.cur_section = id.section
    RightView.show(state, node, id.base, narrow(), root)
  end)

  -- 预览防抖：单例常驻 timer（仿下方 _apply_layout），wait 每次读取最新 config
  local preview_debounced = require('vv-utils.timer').debounce(function()
    M._preview()
  end, function() return config().preview_debounce_ms or 0 end)

  -- CursorMoved 入口：>0 走防抖（光标停顿后才刷新 diff），0 保持同步直刷
  M._preview_on_move = function()
    if (config().preview_debounce_ms or 0) > 0 then
      preview_debounced()
    else
      M._preview()
    end
  end

  M._activate = State.guarded(function(state, expand_only)
    local id = Keymaps.id_under_cursor(state)
    if not id then return end
    if id.section_header or id.block_header then
      M._toggle_fold()
      return
    end
    local node = id.node
    if not node then return end
    if node.is_dir then
      local fold_key = Subrepo.sel_key(id.section or '', node.relpath)
      if not expand_only or state.folds[fold_key] then
        M._toggle_fold()
      end
      return
    end
    local root = id.root or state.git_root
    local abspath = root .. '/' .. node.relpath
    if binary(abspath) then
      require('vv-utils.sys').open_default(abspath)
      return
    end
    state.cur_path = node.relpath
    state.cur_section = id.section
    local view = state.view
    if view and view.path == node.relpath and view.section == id.base and view.root == root
        and view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
      return
    end
    RightView.show(state, node, id.base, narrow(), root)
  end)

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
    RightView.toggle_all_folds(state)
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
      local target = (config().select_move_down ~= false and lnum < last)
          and lnum + 1
          or lnum
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end
  end)

  M._action = State.guarded(function(state, name)
    if state.compare then return end
    -- yank_abs_path 不在 Actions 分派表内（它是 M 上的独立命令、不改动树、无需 hint）：
    -- 直接委派到 M._yank_abs_path，right_click='yank_abs_path' 才能真正触发
    if name == 'yank_abs_path' then
      M._yank_abs_path()
      return
    end
    if next(state.selection) then
      local items = {}
      for key in pairs(state.selection) do
        local root, base, relpath = Subrepo.parse_sel_key(key)
        if base and relpath then
          items[#items + 1] = { root = root or state.git_root, base = base, relpath = relpath }
        end
      end
      local fn = Actions[name .. '_selection']
      -- 仅在确实存在 _selection 处理器时才清空选择：否则缺失处理器会把多选
      -- 静默清掉且什么都不执行（见 accept_ours/accept_theirs 缺 _selection 变体的情形）
      if fn then
        state.selection = {}
        fn(state, items)
      end
      return
    end

    local id = Keymaps.id_under_cursor(state)
    if not id then return end
    if id.node then
      state.cur_path = id.node.relpath
      state.cur_section = id.section
    end
    local fn = Actions[name]
    -- 未识别的 action：直接返回，绝不写 _action_hint——否则残留 hint 会在下次
    -- passive render 时被消费而错位光标
    if not fn then return end
    if id.node and id.section and state.panel and state.panel.win
        and vim.api.nvim_win_is_valid(state.panel.win) then
      local lnum = vim.api.nvim_win_get_cursor(state.panel.win)[1]
      local next_path, prev_path = action_neighbor_leaves(state, id, lnum)
      state._action_hint = { section = id.section, lnum = lnum, next_path = next_path, prev_path = prev_path }
    end
    fn(state, id)
  end)

  -- 右侧 diff buffer 的 `-`：以当前 view 为事实来源，不依赖左栏残留的光标行
  -- 完成 stage/unstage 后，同一文件会移动到另一 section，重新查新树节点并刷新 diff；
  -- reshow 复用既有焦点恢复机制，操作前后都留在用户按键的 diff 窗口
  M._toggle_view_stage = State.guarded(function(state)
    if state.compare then return end
    local view = state.view
    if not view or not view.node then return end
    if view.section ~= 'staged' and view.section ~= 'unstaged' then return end

    local root = view.root or state.git_root
    local relpath = view.node.relpath
    local target_section = view.section == 'staged' and 'unstaged' or 'staged'
    local restore_win = vim.api.nvim_get_current_win()
    local id = {
      root = root,
      base = view.section,
      section = Subrepo.section_id(root, state.git_root, view.section),
      node = view.node,
    }

    Actions.toggle_stage(state, id, function()
      if not State.is_current(state) then return end
      local repo = Subrepo.repo_of(state, root)
      local side = repo and repo.tree and repo.tree[target_section]
      local node = side and Tree.leaf_at(side, relpath)
      if not node then return end

      state.cur_path = relpath
      state.cur_section = Subrepo.section_id(root, state.git_root, target_section)
      if vim.api.nvim_win_is_valid(restore_win) then
        state._reshow_restore_win = restore_win
      end
      RightView.show(state, node, target_section, narrow(), root)
    end)
  end)

  -- layout

  local function do_apply_layout(state)
    if not state.git_root then return end
    local view = state.view
    if not view or not view.node then return end
    if view.intrinsic_single then return end

    local want_single = narrow()
    local is_now_single = (view.mode == 'single')
    if want_single == is_now_single then
      if not want_single then
        M.apply_diff_ratio(state, config().diff_ratio)
      end
      return
    end

    RightView.show(state, view.node, view.section, want_single, view.root)
  end

  -- resize 去抖单例：L.attach 仅初始化时调一次，常驻一个 uv timer
  local apply_layout_debounced = require('vv-utils.timer').debounce(function()
    if State.has() then do_apply_layout(State.get()) end
  end, 50)

  M._apply_layout = State.guarded(function(state)
    ensure_unique_panel(state)
    apply_layout_debounced()
  end)

  return M
end

return L
