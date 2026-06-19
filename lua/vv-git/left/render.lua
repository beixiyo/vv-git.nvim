-- 左栏渲染：顶部 commit 摘要行 + 两个 section（Staged / Changes） + 冲突提示
-- 输出 lines + extmarks + id_by_line（lnum 1-based → {section, node} 或 {section_header=...}）

local Tree = require('vv-git.tree')
local Icons = require('vv-git.icons')
local Panel = require('vv-git.left.panel')
local ui_icons = require('vv-icons').raw.ui

local M = {}

M.ns = vim.api.nvim_create_namespace('vv-git-panel')

local INDENT_STEP = '  '
local ARROW_OPEN = ui_icons.fold_open.glyph
local ARROW_CLOSE = ui_icons.fold_closed.glyph
local ARROW_COLS = 2
-- nerd font 多数 2 cols；若 MiniIcons 返回 1-col 字符，pad_to_cols 会补空格
-- 已知局限：>2 col 的 icon 不会被截断，可能与邻行错位（实际很罕见）
local ICON_COLS = 2

local function pad_to_cols(s, cols)
  local w = vim.fn.strdisplaywidth(s)
  if w >= cols then return s end
  return s .. string.rep(' ', cols - w)
end

---@param opts { depth:integer, is_dir:boolean, is_open:boolean, has_children:boolean, display_name:string, node:table, status_letter?:string, status_hl?:string, section_id?:string, selected?:boolean }
---@return string line, table[] extmarks (无 row)
local function build_row(opts)
  local prefix = string.rep(INDENT_STEP, opts.depth)

  local arrow_raw = ''
  if opts.is_dir then
    arrow_raw = opts.is_open and ARROW_OPEN or ARROW_CLOSE
  end
  local arrow_block = pad_to_cols(arrow_raw, ARROW_COLS)

  local icon, ihl = Icons.resolve({
    name = opts.display_name:match('[^/]+$') or opts.display_name,
    is_dir = opts.is_dir,
    open = opts.is_open,
    has_children = opts.has_children,
  })
  local icon_block = pad_to_cols(icon, ICON_COLS)

  local name = opts.display_name
  local line = prefix .. arrow_block .. icon_block .. name

  local extmarks = {}
  local col = #prefix

  if #arrow_raw > 0 then
    extmarks[#extmarks + 1] = {
      col = col,
      opts = { end_col = col + #arrow_raw, hl_group = 'VVGitPanelIndent' },
    }
  end
  col = col + #arrow_block

  local name_hl = opts.is_dir and 'VVGitPanelDir' or 'VVGitPanelFile'
  local icon_hl = ihl or 'VVGitPanelFile'

  if opts.is_dir and opts.section_id == 'staged' then
    name_hl = 'VVGitPanelStagedDir'
    icon_hl = 'VVGitPanelStagedDir'
  end

  if #icon > 0 then
    extmarks[#extmarks + 1] = {
      col = col,
      opts = { end_col = col + #icon, hl_group = icon_hl },
    }
  end
  col = col + #icon_block

  extmarks[#extmarks + 1] = {
    col = col,
    opts = { end_col = col + #name, hl_group = name_hl },
  }

  -- 行尾状态字母：右对齐到窗口边缘
  if opts.status_letter then
    extmarks[#extmarks + 1] = {
      col = 0,
      opts = {
        virt_text = { { opts.status_letter .. ' ', opts.status_hl or 'VVGitPanelFile' } },
        virt_text_pos = 'right_align',
      },
    }
  end

  if opts.selected then
    extmarks[#extmarks + 1] = {
      col = 0,
      opts = { end_col = 0, line_hl_group = 'VVGitPanelSelected' },
    }
  end

  return line, extmarks
end

---@param state table  vv-git state（含 tree / folds / git_root）
---@return string[] lines, table[] extmarks, table id_by_line
function M.build(state)
  local lines = {}
  local extmarks = {}
  local id_by_line = {}

  ---@param s string
  ---@param hl? string
  local function push_text(s, hl)
    lines[#lines + 1] = s
    if hl then
      extmarks[#extmarks + 1] = { row = #lines - 1, col = 0, opts = { end_col = #s, hl_group = hl } }
    end
  end

  local function push_blank() lines[#lines + 1] = '' end

  -- Header: 仓库名
  local root_name = vim.fn.fnamemodify(state.git_root or '', ':t')
  push_text(' ' .. root_name, 'Title')
  push_blank()

  local tree = state.tree
  local folds = state.folds or {}
  local section_folds = state.section_folds or {}

  ---@param section_id 'staged'|'unstaged'|'conflicts'
  ---@param title string
  ---@param side_root table
  local function render_section(section_id, title, side_root)
    if Tree.empty(side_root) then return end

    local collapsed = section_folds[section_id] == true

    local count = Tree.count_files(side_root)
    -- 行首箭头占位（与文件夹行的 arrow_block 同宽，2 cols），点击/回车可折叠整个 section
    local arrow_raw = collapsed and ARROW_CLOSE or ARROW_OPEN
    local arrow_block = pad_to_cols(arrow_raw, ARROW_COLS)
    local body = string.format('%s (%d)', title, count)
    local header = arrow_block .. body
    lines[#lines + 1] = header
    local row = #lines - 1

    local title_hl = 'VVGitPanelSection'
    if section_id == 'staged' then
      title_hl = 'VVGitPanelStagedDir'
    end

    local title_col = #arrow_block
    extmarks[#extmarks + 1] = {
      row = row, col = 0,
      opts = { end_col = #arrow_raw, hl_group = 'VVGitPanelIndent' },
    }
    extmarks[#extmarks + 1] = {
      row = row, col = title_col,
      opts = { end_col = title_col + #title, hl_group = title_hl },
    }
    extmarks[#extmarks + 1] = {
      row = row, col = title_col + #title + 1,
      opts = { end_col = #header, hl_group = 'VVGitPanelSectionCount' },
    }
    id_by_line[#lines] = { section_header = section_id }

    -- section 折叠：只保留标题行，跳过文件列表
    if collapsed then
      push_blank()
      return
    end

    -- fold key 加 section 前缀，避免 staged/unstaged 同名目录共享折叠状态
    local scoped_folds = {}
    for k, v in pairs(folds) do
      local s, p = k:match('^(.-):(.*)')
      if s == section_id then scoped_folds[p] = v end
    end

    local rows = Tree.flatten(side_root, scoped_folds, { group_empty_dirs = true })
    for _, r in ipairs(rows) do
      local node = r.node
      -- 文件夹行不显示 git 状态，仅文件 leaf 显示状态字母
      local letter, hl
      if not node.is_dir then
        letter, hl = node.letter, node.hl
      end

      local sel_key = section_id .. ':' .. node.relpath
      local line, ems = build_row({
        depth = r.depth + 1, -- section 内再缩进一层
        is_dir = node.is_dir,
        is_open = node.is_dir and not scoped_folds[node.relpath],
        has_children = r.has_children,
        display_name = r.display_name,
        node = node,
        status_letter = letter,
        status_hl = hl,
        section_id = section_id,
        selected = not node.is_dir and (state.selection or {})[sel_key] == true,
      })
      lines[#lines + 1] = line
      local lnum = #lines - 1
      for _, em in ipairs(ems) do
        extmarks[#extmarks + 1] = { row = lnum, col = em.col, opts = em.opts }
      end
      id_by_line[#lines] = { section = section_id, node = node }
    end

    push_blank()
  end

  -- 比较模式：替换普通 section，展示 commit..HEAD 变更文件列表（树结构）
  if state.compare then
    local cmp = state.compare

    local header = string.format('  Compare (%d files)  %s', #cmp.files, cmp.label)
    lines[#lines + 1] = header
    local hrow = #lines - 1
    extmarks[#extmarks + 1] = {
      row = hrow, col = 0,
      opts = { end_col = 12, hl_group = 'VVGitPanelSection' },
    }
    extmarks[#extmarks + 1] = {
      row = hrow, col = 13,
      opts = { end_col = #header, hl_group = 'Comment' },
    }
    -- 不给 compare header 赋 section_header：compare 渲染从不读 section_folds['compare']，
    -- 折叠点击对它无效。留空 id 让 _toggle_fold/_collapse/_activate 在该行直接 return，
    -- 避免死写 section_folds['compare']（其下目录折叠走 folds 表 'compare:' 前缀，不受影响）

    local compare_root = Tree.build_compare(cmp.files)
    local scoped_folds = {}
    for k, v in pairs(folds) do
      local s, p = k:match('^(.-):(.*)')
      if s == 'compare' then scoped_folds[p] = v end
    end

    local rows = Tree.flatten(compare_root, scoped_folds, { group_empty_dirs = true })
    for _, r in ipairs(rows) do
      local node = r.node
      -- 文件夹行不显示 git 状态，仅文件 leaf 显示状态字母
      local letter, hl
      if not node.is_dir then
        letter, hl = node.letter, node.hl
      end

      local display = r.display_name
      if not node.is_dir and node.old_relpath then
        local old_name = node.old_relpath:match('[^/]+$') or node.old_relpath
        display = old_name .. ' → ' .. display
      end

      local line, ems = build_row({
        depth          = r.depth + 1,
        is_dir         = node.is_dir,
        is_open        = node.is_dir and not scoped_folds[node.relpath],
        has_children   = r.has_children,
        display_name   = display,
        node           = node,
        status_letter  = letter,
        status_hl      = hl,
      })
      lines[#lines + 1] = line
      local lnum = #lines - 1
      for _, em in ipairs(ems) do
        extmarks[#extmarks + 1] = { row = lnum, col = em.col, opts = em.opts }
      end
      id_by_line[#lines] = { section = 'compare', node = node }
    end

    push_blank()
    push_text('  <Esc>  Exit compare mode', 'Comment')

    return lines, extmarks, id_by_line
  end

  -- 普通模式：commit hint + 三个 section
  if not tree then
    push_text('  (Waiting for git status...)', 'Comment')
    return lines, extmarks, id_by_line
  end

  local staged_count = Tree.count_files(tree.staged)
  local unstaged_count = Tree.count_files(tree.unstaged)
  local hint
  if staged_count > 0 then
    hint = string.format('  c  Commit %d staged', staged_count)
  elseif unstaged_count > 0 then
    hint = string.format('  c  Commit ALL %d (no staged)', unstaged_count)
  else
    hint = '  working tree clean'
  end
  push_text(hint, 'VVGitCommitHint')

  if state.ahead_count and state.ahead_count > 0 then
    push_text(string.format('  p  Push %d commit(s)', state.ahead_count), 'VVGitCommitHint')
  end
  push_blank()

  -- 冲突优先显示（VSCode 风）
  render_section('conflicts', 'Merge Conflicts', tree.conflicts)
  render_section('staged', 'Staged Changes', tree.staged)
  render_section('unstaged', 'Changes', tree.unstaged)

  return lines, extmarks, id_by_line
end

---@param state table
---@param passive boolean?  被动刷新（auto_refresh / 保存 / gitsigns / R / commit-push）：
---  渲染前记下光标当前所在文件、渲染后放回同一文件，不读可能滞后的 cur_path、不管焦点在不在 panel
function M.render(state, passive)
  if not state.panel or not state.panel.buf then return end
  if not vim.api.nvim_buf_is_valid(state.panel.buf) then return end

  -- passive 刷新防拉扯：在 flush 重写 buffer **之前**，从旧 id_by_line 反查光标当前所在的文件节点。
  -- 纯 j/k 导航时 preview 的 set_buf 会发 BufEnter 反复点起 auto_refresh → 这条 passive 渲染；
  -- 若像普通渲染那样按 cur_path 恢复，cur_path 由防抖 preview 滞后约 150ms、落后于光标真实行，
  -- 就会把刚导航到的位置拉回旧行、且自触发 CursorMoved 形成自激回环。改为记住「光标此刻在哪个
  -- 文件」、渲染后放回该文件（content 变了就跟它到新行），令本次刷新对光标成为 no-op。
  -- 带 hint（stage/unstage/fold，非 passive）的渲染不进此分支，afc82c2 等落点逻辑不受影响
  local keep
  if passive and not state._action_hint and not state._section_hint then
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

  local lines, extmarks, id_by_line = M.build(state)
  Panel.flush(state.panel.buf, lines, extmarks, M.ns)
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
      local lnum = (cur_section and line_of(cur_path, cur_section))
          or line_of(cur_path, 'unstaged')
          or line_of(cur_path, 'staged')
          or line_of(cur_path, 'conflicts')
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
