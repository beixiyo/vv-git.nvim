-- 左栏内容构建：生成面板文本、extmarks 与行级节点索引
-- 输出 lines + extmarks + id_by_line（lnum 1-based → {section, node} 或 {section_header=...}）

local Tree = require('vv-git.tree')
local Icons = require('vv-git.icons')
local Subrepo = require('vv-git.subrepo')
local ui_icons = require('vv-icons').raw.ui
local git_icons = require('vv-icons').raw.git

local M = {}

local INDENT_STEP = '  '
local ARROW_OPEN = ui_icons.fold_open.glyph
local ARROW_CLOSE = ui_icons.fold_closed.glyph
local ARROW_COLS = 2
local BRANCH_ICON = (git_icons.git_branches or {}).glyph or ''
local BRANCH_ICON_HL = (git_icons.git_branches or {}).hl or 'VVGitPanelBranch' -- 语义色（MiniIconsOrange）
-- nerd font 多数 2 cols；若 MiniIcons 返回 1-col 字符，pad_to_cols 会补空格
-- 已知局限：>2 col 的 icon 不会被截断，可能与邻行错位（实际很罕见）
local ICON_COLS = 2

local function count_label(count, singular, plural)
  return string.format('%d %s', count, count == 1 and singular or plural)
end

---@param info VVGitRepoInfo?
local function needs_remote_action(info)
  if not info then return false end
  if info.upstream then return info.ahead > 0 or info.behind > 0 end
  return not info.detached and not info.unborn and info.head ~= nil and info.branch_name ~= nil
end

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

  ---@param key string
  ---@param text string
  ---@param text_hl? string
  ---@param root? string  hint 所属仓库；让 c/p/P/u 在子仓库 hint 行正确路由
  ---@param indent? integer
  ---@param id? table  非仓库决策页的可选行标识
  local function push_key_hint(key, text, text_hl, root, indent, id)
    local prefix = string.rep(INDENT_STEP, indent or 1)
    local line = prefix .. key .. '  ' .. text
    push_text(line, text_hl or 'VVGitCommitHint')
    extmarks[#extmarks + 1] = {
      row = #lines - 1,
      col = #prefix,
      opts = {
        end_col = #prefix + #key,
        hl_group = 'VVGitPanelKey',
        -- Neovim 0.12 给未显式指定 priority 的整行 extmark 使用 4096；
        -- 按键必须更高，否则会被 VVGitCommitHint / Comment 的整行颜色覆盖
        priority = 5000,
      },
    }
    if id then
      id_by_line[#lines] = id
    elseif root then
      id_by_line[#lines] = { root = root, action_hint = true }
    end
  end

  local function push_blank() lines[#lines + 1] = '' end

  -- 渲染一个仓库块标题行（根仓库 / 子仓库通用）：
  --   `<箭头> <分支icon> <分支>  <name>`
  -- 箭头可折叠（block_header=root）；分支 icon 用其自身语义色（MiniIconsOrange），
  -- 分支名用主题关键字色（VVGitPanelBranch），name 由调用方指定 hl（根=Title，子仓库=VVGitPanelSubrepo）
  ---@param root string  仓库根（折叠 key / id.block_header）
  ---@param name string  显示名（根=仓库名，子仓库=相对路径）
  ---@param name_hl string
  ---@param branch string?
  ---@return boolean collapsed
  local function render_repo_header(root, name, name_hl, branch)
    local collapsed = (state.block_folds or {})[root] == true
    local arrow_raw = collapsed and ARROW_CLOSE or ARROW_OPEN
    local header = pad_to_cols(arrow_raw, ARROW_COLS)
    local ems = { { col = 0, len = #arrow_raw, hl = 'VVGitPanelIndent' } }

    -- 分支前缀： 󰘬 <branch>（icon 与 branch 分别使用语义色），放在 name 之前
    if branch and branch ~= '' then
      if BRANCH_ICON ~= '' then
        ems[#ems + 1] = { col = #header, len = #BRANCH_ICON, hl = BRANCH_ICON_HL }
        header = header .. BRANCH_ICON .. ' '
      end
      ems[#ems + 1] = { col = #header, len = #branch, hl = 'VVGitPanelBranch' }
      header = header .. branch .. '  '
    end

    ems[#ems + 1] = { col = #header, len = #name, hl = name_hl }
    header = header .. name

    lines[#lines + 1] = header
    local row = #lines - 1
    for _, e in ipairs(ems) do
      extmarks[#extmarks + 1] = { row = row, col = e.col, opts = { end_col = e.col + e.len, hl_group = e.hl } }
    end
    id_by_line[#lines] = { block_header = root, root = root }
    return collapsed
  end

  if state.init_root then
    local root_name = vim.fn.fnamemodify(state.init_root, ':t')
    push_text(INDENT_STEP .. root_name, 'Title')
    push_blank()
    if state._initializing_repository then
      push_text(INDENT_STEP .. 'Initializing Git repository...', 'Comment')
    elseif state.parent_root then
      push_text(INDENT_STEP .. 'Parent Git repository found', 'Comment')
      push_text(INDENT_STEP .. state.parent_root, 'VVGitCommitHint')
      push_blank()
      push_key_hint('p', 'Open parent repository', nil, nil, nil, { repository_action = 'parent' })
      push_key_hint('i', 'Initialize Git repository here', nil, nil, nil, { repository_action = 'init' })
    else
      push_text(INDENT_STEP .. 'Not a Git repository', 'Comment')
      push_key_hint('i', 'Initialize Git repository', nil, nil, nil, { repository_action = 'init' })
    end
    return lines, extmarks, id_by_line
  end

  -- Header: 根仓库块标题（可折叠：折叠后只留标题行，隐藏 commit 提示与父仓库 section）
  local root_name = vim.fn.fnamemodify(state.git_root or '', ':t')
  local root_collapsed = render_repo_header(state.git_root, root_name, 'Title', state.branch)
  push_blank()

  local tree = state.tree
  local folds = state.folds or {}
  local section_folds = state.section_folds or {}

  ---@param root string
  ---@param repo_tree table
  ---@param info VVGitRepoInfo?
  ---@param indent? integer
  local function render_repo_summary(root, repo_tree, info, indent)
    indent = indent or 1
    local staged_count = Tree.count_files(repo_tree.staged)
    local unstaged_count = Tree.count_files(repo_tree.unstaged)

    if staged_count > 0 then
      push_key_hint('c', 'Commit ' .. count_label(staged_count, 'staged file', 'staged files'), nil, root, indent)
    elseif unstaged_count > 0 then
      push_key_hint('c', 'Commit all ' .. count_label(unstaged_count, 'file', 'files'), nil, root, indent)
    else
      push_text(string.rep(INDENT_STEP, indent) .. 'working tree clean', 'VVGitCommitHint')
    end

    if info then
      if info.upstream then
        if info.ahead > 0 then
          push_key_hint('p', 'Push ' .. count_label(info.ahead, 'commit', 'commits'), nil, root, indent)
        end
        if info.behind > 0 then
          push_key_hint('P', 'Pull ' .. count_label(info.behind, 'commit', 'commits'), nil, root, indent)
        end
      elseif not info.detached and not info.unborn and info.head and info.branch_name then
        push_key_hint('u', 'Publish ' .. info.branch_name, nil, root, indent)
      end
    end
    push_blank()
  end

  ---@param root string  该 section 所属仓库根（父仓库 = state.git_root）
  ---@param base 'staged'|'unstaged'|'conflicts'
  ---@param title string
  ---@param side_root table
  ---@param indent integer?  额外缩进层数（子仓库块内 = 1）
  local function render_section(root, base, title, side_root, indent)
    if Tree.empty(side_root) then return end
    indent = indent or 0

    -- section_id：父仓库为裸 base，子仓库为 root\0base，让 fold/selection key 按仓库隔离
    local section_id = Subrepo.section_id(root, state.git_root, base)
    local seg = string.rep(INDENT_STEP, indent)
    local collapsed = section_folds[section_id] == true

    local count = Tree.count_files(side_root)
    -- 行首箭头占位（与文件夹行的 arrow_block 同宽，2 cols），点击/回车可折叠整个 section
    local arrow_raw = collapsed and ARROW_CLOSE or ARROW_OPEN
    local arrow_block = pad_to_cols(arrow_raw, ARROW_COLS)
    local body = string.format('%s (%d)', title, count)
    local header = seg .. arrow_block .. body
    lines[#lines + 1] = header
    local row = #lines - 1

    local title_hl = (base == 'staged') and 'VVGitPanelStagedDir' or 'VVGitPanelSection'

    local arrow_col = #seg
    local title_col = #seg + #arrow_block
    extmarks[#extmarks + 1] = {
      row = row, col = arrow_col,
      opts = { end_col = arrow_col + #arrow_raw, hl_group = 'VVGitPanelIndent' },
    }
    extmarks[#extmarks + 1] = {
      row = row, col = title_col,
      opts = { end_col = title_col + #title, hl_group = title_hl },
    }
    extmarks[#extmarks + 1] = {
      row = row, col = title_col + #title + 1,
      opts = { end_col = #header, hl_group = 'VVGitPanelSectionCount' },
    }
    id_by_line[#lines] = { section_header = section_id, base = base, root = root }

    -- section 折叠：只保留标题行，跳过文件列表
    if collapsed then
      push_blank()
      return
    end

    -- fold key 加 section_id 前缀，避免 staged/unstaged（及跨仓库）同名目录共享折叠状态
    local scoped_folds = {}
    for k, v in pairs(folds) do
      local s, p = Subrepo.split_key(k)
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

      local sel_key = Subrepo.sel_key(section_id, node.relpath)
      local line, ems = build_row({
        depth = r.depth + 1 + indent, -- section 内再缩进一层（子仓库块再 +1）
        is_dir = node.is_dir,
        is_open = node.is_dir and not scoped_folds[node.relpath],
        has_children = r.has_children,
        display_name = r.display_name,
        node = node,
        status_letter = letter,
        status_hl = hl,
        section_id = base,
        selected = not node.is_dir and (state.selection or {})[sel_key] == true,
      })
      lines[#lines + 1] = line
      local lnum = #lines - 1
      for _, em in ipairs(ems) do
        extmarks[#extmarks + 1] = { row = lnum, col = em.col, opts = em.opts }
      end
      id_by_line[#lines] = { section = section_id, base = base, root = root, node = node }
    end

    push_blank()
  end

  -- 渲染一个子仓库块：标题（相对路径 + 分支，可折叠）+ 其三个 section（缩进一层）
  ---@param sr table  { root, label, tree, branch }
  local function render_subrepo(sr)
    local t = sr.tree
    local has_changes = not Tree.empty(t.staged) or not Tree.empty(t.unstaged) or not Tree.empty(t.conflicts)
    if not has_changes and not needs_remote_action(sr.repo_info) then
      return -- 该子仓库无改动，不渲染空块
    end

    -- 标题不写「Sub-Repo:」字面——块的缩进结构已表明它是子仓库
    local collapsed = render_repo_header(sr.root, sr.label, 'VVGitPanelSubrepo', sr.branch)
    if collapsed then
      push_blank() -- 折叠整个块：只保留标题行
      return
    end

    push_blank()
    render_repo_summary(sr.root, t, sr.repo_info, 2)
    render_section(sr.root, 'conflicts', 'Merge Conflicts', t.conflicts, 1)
    render_section(sr.root, 'staged', 'Staged Changes', t.staged, 1)
    render_section(sr.root, 'unstaged', 'Changes', t.unstaged, 1)
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
      local s, p = Subrepo.split_key(k)
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
      id_by_line[#lines] = { section = 'compare', base = 'compare', node = node }
    end

    push_blank()
    push_key_hint('<Esc>', 'Exit compare mode', 'Comment')

    return lines, extmarks, id_by_line
  end

  -- 普通模式：commit hint + 三个 section
  if not tree then
    push_text('  (Waiting for git status...)', 'Comment')
    return lines, extmarks, id_by_line
  end

  -- 根仓库折叠：隐藏 action 提示与三个父 section，只保留已渲染的标题行；子仓库块照常
  if not root_collapsed then
    render_repo_summary(state.git_root, tree, state.repo_info)

    -- 父仓库（冲突优先显示，VSCode 风）
    render_section(state.git_root, 'conflicts', 'Merge Conflicts', tree.conflicts)
    render_section(state.git_root, 'staged', 'Staged Changes', tree.staged)
    render_section(state.git_root, 'unstaged', 'Changes', tree.unstaged)
  end

  -- 子仓库块：每个发现的子仓库作为独立块（含各自的 staged/changes），不受根折叠影响
  for _, sr in ipairs(state.subrepos or {}) do
    render_subrepo(sr)
  end

  return lines, extmarks, id_by_line
end

return M
