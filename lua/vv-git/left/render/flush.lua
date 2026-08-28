-- 左栏刷新：写入 buffer，并在被动刷新或动作后恢复光标

local Tree = require('vv-git.tree')
local Panel = require('vv-git.left.panel')
local Subrepo = require('vv-git.subrepo')

local M = {}

-- fold_staged 只是 fresh-open 的默认值。若当前文件仅在 staged 中，或整棵树
-- 只有 staged changes，初次渲染需展开 section 才能让光标落到文件行。这个判定
-- 必须只消费一次并同步真实 fold state，否则后续每次 render 都会抵消用户手动折叠
---@param state table
local function apply_fold_staged_default(state)
  local tree = state.tree
  if not state._fold_staged_pending or not tree then return end

  state._fold_staged_pending = nil

  local staged_id = Subrepo.section_id(state.git_root, state.git_root, 'staged')
  local staged_collapsed = (state.section_folds or {})[staged_id] == true
  if not staged_collapsed then return end

  local only_staged = Tree.empty(tree.unstaged) and Tree.empty(tree.conflicts)
  local target_in_staged = state.cur_path and Tree.leaf_at(tree.staged, state.cur_path) ~= nil
  local target_in_worktree = false
  if state.cur_path then
    target_in_worktree = Tree.leaf_at(tree.unstaged, state.cur_path) ~= nil
        or Tree.leaf_at(tree.conflicts, state.cur_path) ~= nil
  end

  if only_staged or (target_in_staged and not target_in_worktree) then
    state.section_folds[staged_id] = nil
  end
end

---@param state table
---@param passive boolean?  被动刷新（auto_refresh / 保存 / gitsigns / R / commit-push）：
---  渲染前记下光标当前所在文件、渲染后放回同一文件，不读可能滞后的 cur_path、不管焦点在不在 panel
function M.render(state, passive, build, ns)
  if not state.panel or not state.panel.buf then return end
  if not vim.api.nvim_buf_is_valid(state.panel.buf) then return end

  apply_fold_staged_default(state)

  -- passive 刷新防拉扯：在 flush 重写 buffer **之前**，从旧 id_by_line 反查光标当前所在的文件节点
  -- 纯 j/k 导航时 preview 的 set_buf 会发 BufEnter 反复点起 auto_refresh → 这条 passive 渲染；
  -- 若像普通渲染那样按 cur_path 恢复，cur_path 由防抖 preview 滞后约 150ms、落后于光标真实行，
  -- 就会把刚导航到的位置拉回旧行、且自触发 CursorMoved 形成自激回环。改为记住「光标此刻在哪个
  -- 文件」、渲染后放回该文件（content 变了就跟它到新行），令本次刷新对光标成为 no-op
  -- 带 hint（stage/unstage/fold，非 passive）的渲染不进此分支，afc82c2 等落点逻辑不受影响
  local keep
  if passive and not state._action_hint and not state._section_hint and not state._block_hint then
    local pw = state.panel.win
    if pw and vim.api.nvim_win_is_valid(pw) then
      local ok, pos = pcall(vim.api.nvim_win_get_cursor, pw)
      if ok and pos then
        local oid = (state.panel.id_by_line or {})[pos[1]]
        keep = {
          line = pos[1],
          relpath = oid and oid.node and not oid.node.is_dir and oid.node.relpath or nil,
          section = oid and oid.section or nil,
        }
      end
    end
  end

  local lines, extmarks, id_by_line = build(state)
  Panel.flush(state.panel.buf, lines, extmarks, ns)
  state.panel.id_by_line = id_by_line

  -- relpath(+可选 section)→ 行号：render 内多处光标恢复共用的定位原语
  -- （section 为 nil 时不约束；同名文件可能并存于 staged/unstaged，故按需带 section 过滤）
  local function line_of(relpath, section)
    if not relpath then return nil end
    for lnum, id in pairs(id_by_line) do
      if id.node and id.node.relpath == relpath and (not section or id.section == section) then
        return lnum
      end
    end
  end

  -- 记住当前光标 → 尝试恢复到 cur_path
  -- （初次渲染时光标可能在 header，跳到第一个文件行更合理）
  local win = state.panel.win
  if win and vim.api.nvim_win_is_valid(win) then
    -- 非仓库决策页只有一到两个明确动作：普通空目录默认 init；发现祖先仓库时，
    -- 被父仓库忽略的目录默认 init，否则默认打开父仓库。j/k 与 <CR> 仍可切换并执行
    if state.init_root and not state._initializing_repository then
      local preferred = state.parent_root
          and (state.parent_ignored and 'init' or 'parent')
          or 'init'
      for lnum, id in pairs(id_by_line) do
        if id.repository_action == preferred then
          pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
          return
        end
      end
    end

    -- passive：把光标放回它原本所在的文件（content 变了跟该文件到新行，找不到再按原行号 clamp），
    -- 不进入下方按 cur_path 的恢复，避免被滞后值拉走
    if keep then
      local target = line_of(keep.relpath, keep.section)
          or math.min(keep.line, math.max(1, #lines))
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
      local id = id_by_line[target]
      if id and id.node then
        state.cur_path = id.node.relpath
        state.cur_section = id.section
      end
      return
    end

    -- section 折叠/展开后：把光标固定在该 section 标题行，避免跳到别处
    local sh = state._section_hint
    if sh then
      state._section_hint = nil
      for lnum = 1, #lines do
        local id = id_by_line[lnum]
        if id and id.section_header == sh then
          pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
          return
        end
      end
    end

    -- Sub-Repo 块折叠/展开后：把光标固定在该块标题行
    local rh = state._block_hint
    if rh then
      state._block_hint = nil
      for lnum = 1, #lines do
        local id = id_by_line[lnum]
        if id and id.block_header == rh then
          pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
          return
        end
      end
    end

    -- 动作触发的渲染：落到动作前记下的「下一个文件」（跳过目录），在原 section 内顺势下移，
    -- 避免跨 section 跳动。绝对行号会因 Staged section 增长而漂移，故优先按 relpath 定位
    local hint = state._action_hint
    if hint then
      state._action_hint = nil

      -- relpath → 行号（限定同 section 且为文件 leaf）
      local function find_leaf(relpath)
        if not relpath then return nil end
        for lnum = 1, #lines do
          local id = id_by_line[lnum]
          if id and id.section == hint.section and id.node
              and not id.node.is_dir and id.node.relpath == relpath then
            return lnum
          end
        end
      end

      -- ① 下一个文件 → ② 没有则上一个文件 → ③ 仍没有则原 section 内从旧行号向下找首个文件
      local target = find_leaf(hint.next_path) or find_leaf(hint.prev_path)
      if not target then
        for lnum = hint.lnum, #lines do
          local id = id_by_line[lnum]
          if id and id.section == hint.section and id.node and not id.node.is_dir then
            target = lnum
            break
          end
        end
      end

      if target then
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
        local id = id_by_line[target]
        state.cur_path = id and id.node and id.node.relpath or nil
        if id and id.section then state.cur_section = id.section end
        return
      end
      -- ④ 该 section 已被清空（acted 是其唯一文件）：旧绝对行号已失效，不再 clamp
      -- 落空，交给下方通用 cur_path 恢复——它跨 section 按 relpath 找到 acted 文件的新位置
      -- （stage→落到 Staged 副本；unstage→落到 Changes 副本；discard 后文件不存在则退到首个文件）
    end

    local cur_path = state.cur_path
    local cur_section = state.cur_section
    if cur_path then
      -- 优先匹配同 section 同 path；再不行按 Changes 优先（同名文件可能并存于 staged/unstaged）
      -- fallback 的三个候选 section 必须落在 cur_section 所属的同一仓库：父仓库得裸 base、
      -- 子仓库得 `<root>\0base`，否则子仓库文件离开旧分区后裸 base 永远匹配不到复合 section_id，
      -- 光标会被甩出 Sub-Repo 块跳到父仓库（见 cur_section 写入点：子仓库节点 = 复合 id）
      local cur_root = cur_section and Subrepo.parse_section_id(cur_section) or nil
      local function side_id(base) return Subrepo.section_id(cur_root, state.git_root, base) end
      local lnum = (cur_section and line_of(cur_path, cur_section))
          or line_of(cur_path, side_id('unstaged'))
          or line_of(cur_path, side_id('staged'))
          or line_of(cur_path, side_id('conflicts'))
      if lnum then
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
        return
      end
    end
    -- 优先落在 Changes（unstaged）的第一个文件行
    for lnum = 1, #lines do
      local id = id_by_line[lnum]
      if id and id.node and not id.node.is_dir and id.section == 'unstaged' then
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
        return
      end
    end
    for lnum = 1, #lines do
      local id = id_by_line[lnum]
      if id and id.node and not id.node.is_dir then
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
        return
      end
    end
  end
end

return M
