-- panel 文件打开、暂存/丢弃/冲突处理及右侧 diff 暂存切换

local State = require('vv-git.state')

local L = {}

---@param context table
---@param toggle_fold fun()?
---@return table
function L.new(context, toggle_fold)
  local M = {}
  local Subrepo = context.Subrepo
  local Tree = context.Tree
  local Keymaps = context.Keymaps
  local RightView = context.RightView
  local Actions = context.Actions
  local function narrow() return context.narrow() end
  local function binary(path) return context.binary(path) end

  -- 动作（stage/unstage/discard/accept）触发渲染后，把光标落到「下一个文件」
  -- 仅靠旧的绝对行号 hint.lnum 不可靠：stage 会把文件移到上方的 Staged section，
  -- 该 section 增长把下方 Changes 整体顶下去，旧行号便指向了被暂存文件「上方」的条目，
  -- 表现为光标无规律上跳。改为在动作前记下同 section 内**下一个 / 上一个文件**的 relpath，
  -- 渲染后按 relpath 定位，自然跳过目录行
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
          prev_path = e.node.relpath
        end
      end
    end

    return next_path, prev_path
  end

  M._activate = State.guarded(function(state, expand_only)
    local id = Keymaps.id_under_cursor(state)
    if not id then return end
    if id.repository_action == 'init' then
      context.controller._init_repository()
      return
    end
    if id.repository_action == 'parent' then
      context.controller._open_parent_repository()
      return
    end
    if id.section_header or id.block_header then
      if toggle_fold then toggle_fold() end
      return
    end
    local node = id.node
    if not node then return end
    if node.is_dir then
      local fold_key = Subrepo.sel_key(id.section or '', node.relpath)
      if not expand_only or state.folds[fold_key] then
        if toggle_fold then toggle_fold() end
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

  M._action = State.guarded(function(state, name)
    if state.compare then return end
    -- yank_abs_path 不在 Actions 分派表内（它是 controller 上的独立命令、不改动树、无需 hint）
    if name == 'yank_abs_path' then
      if context.controller._yank_abs_path then context.controller._yank_abs_path() end
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

    -- stage/unstage 是异步写入。按键当下先沿旧树移动光标，使下一次快速 `-`
    -- 捕获下一个明确文件；Git 完成后的 reload 再以 action hint 校正最终落点
    if name == 'toggle_stage' and id.node and state._action_hint then
      local target_path = state._action_hint.next_path or state._action_hint.prev_path

      if target_path then
        for lnum, panel_id in pairs(state.panel.id_by_line or {}) do
          if panel_id.section == id.section and panel_id.node
              and not panel_id.node.is_dir and panel_id.node.relpath == target_path then
            pcall(vim.api.nvim_win_set_cursor, state.panel.win, { lnum, 0 })

            state.cur_path = target_path
            state.cur_section = id.section
            break
          end
        end
      end
    end
  end)

  -- 右侧 diff buffer 的 `-`：只操作当前 diff buffer 里可见的那个文件，绝不代用户
  -- 推进到看不见的邻居。完成 stage/unstage 后，同一文件会移动到另一 section，
  -- 重新查新树节点并刷新 diff；reshow 复用既有焦点恢复机制，操作前后都留在用户按键的 diff 窗口
  M._toggle_view_stage = State.guarded(function(state)
    if state.compare then return end
    local view = state.view
    if not view or not view.node then return end
    if view.section ~= 'staged' and view.section ~= 'unstaged' then return end

    -- `-` 是按 buffer 安装的共享映射（right/keymaps 无 per-view 闭包），已被顶掉的旧
    -- diff buffer 在 wipe 前仍会响应；只接受当前 view 自己的 buffer，避免误操作
    local cur_buf = vim.api.nvim_get_current_buf()
    if cur_buf ~= view.a_buf and cur_buf ~= view.b_buf then return end

    local root = view.root or state.git_root
    local relpath = view.node.relpath
    local target_section = view.section == 'staged' and 'unstaged' or 'staged'

    -- 同一目标的 toggle 仍在飞行中时忽略后续按键
    local inflight = state._view_stage_inflight
    if not inflight then
      inflight = {}
      state._view_stage_inflight = inflight
    end
    local inflight_key = table.concat({ root, view.section, relpath }, '\0')
    if inflight[inflight_key] then return end
    inflight[inflight_key] = true

    local restore_win = vim.api.nvim_get_current_win()
    local id = {
      root = root,
      base = view.section,
      section = Subrepo.section_id(root, state.git_root, view.section),
      node = view.node,
    }

    local acted_lnum
    for lnum, panel_id in pairs((state.panel and state.panel.id_by_line) or {}) do
      if panel_id.section == id.section and panel_id.node
          and panel_id.node.relpath == relpath then
        acted_lnum = lnum
        break
      end
    end

    local next_path, prev_path
    if acted_lnum then
      next_path, prev_path = action_neighbor_leaves(state, id, acted_lnum)
      state._action_hint = {
        section = id.section,
        lnum = acted_lnum,
        next_path = next_path,
        prev_path = prev_path,
      }
    end

    Actions.toggle_stage(state, id, function()
      if not State.is_current(state) then return end
      local repo = Subrepo.repo_of(state, root)
      local section, path, node

      for _, candidate in ipairs({ next_path, prev_path }) do
        local side = candidate and repo and repo.tree and repo.tree[view.section]
        local found = side and Tree.leaf_at(side, candidate)
        if found then
          section, path, node = view.section, candidate, found
          break
        end
      end

      if not node then
        local side = repo and repo.tree and repo.tree[target_section]
        section, path = target_section, relpath
        node = side and Tree.leaf_at(side, path)
      end

      if not node then return end

      state.cur_path = path
      state.cur_section = Subrepo.section_id(root, state.git_root, section)
      if vim.api.nvim_win_is_valid(restore_win) then
        state._reshow_restore_win = restore_win
      end
      RightView.show(state, node, section, narrow(), root)
    end, function()
      inflight[inflight_key] = nil
    end)
  end)

  return M
end

return L
