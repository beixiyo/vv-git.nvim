-- worktree.lua — 管理当前仓库的 git worktree：创建、切换、删除与刷新
--
-- 窗口、行号与条目的对应、光标保持、页脚按键提示都交给 vv-utils.ui_view；
-- 这里负责异步拉取列表、按内容收紧浮窗尺寸，以及各动作的业务流程

local Git = require('vv-git.git')
local Async = require('vv-utils.async')
local State = require('vv-git.state')
local Loading = require('vv-utils.loading')
local Rows = require('vv-utils.ui_rows')
local UIView = require('vv-utils.ui_view')
local Create = require('vv-git.worktree.create')
local Remove = require('vv-git.worktree.remove')

local VVIcons = require('vv-icons')
local RawIcons = VVIcons.raw
local RawUI = RawIcons.ui
local RawGit = RawIcons.git

local BRANCH_ENTRY = RawGit.git_branches or {}
local BRANCH_ICON = BRANCH_ENTRY.glyph or ''
local BRANCH_ICON_HL = BRANCH_ENTRY.hl or 'VVGitPanelBranch'

local ADD_ENTRY = RawUI.new_file or {}
local REMOVE_ENTRY = RawGit.git_removed or {}
local HELP_ENTRY = RawUI.keymaps or {}
local CLOSE_ENTRY = RawUI.quit or {}
local REFRESH_ICON = '󰑐'
local CUR_MARK = '●'

local DESC_PREFIX = 'vv-git-worktree'
local TITLE = 'Worktrees'
local MIN_WIDTH = 48
local COLUMN_GAP = 2

local M = {}

local function ref_label(wt)
  if wt.branch then return wt.branch end
  if wt.detached then return '(detached ' .. ((wt.head or '???????'):sub(1, 7)) .. ')' end
  return '(unknown)'
end

local function tilde(path)
  local home = vim.fs.normalize(vim.env.HOME or '')
  if home ~= '' and path:sub(1, #home) == home then return '~' .. path:sub(#home + 1) end
  return path
end

---把 worktree 列表排成两列条目：当前标记 + 图标 + 分支名，路径 + 状态标签
---@param list VVGitWorktree[]
---@param root string 当前 worktree 的规范化路径
---@param max_width? integer 条目内容可用的显示宽度；超出时截断路径，状态标签始终可见
---@return VVUIViewItem[] items
local function build_items(list, root, max_width)
  local heads, paths, tags, ref_ends = {}, {}, {}, {}
  local head_width = 0
  for index, wt in ipairs(list) do
    local is_current = vim.fs.normalize(wt.path) == root
    local head = { { is_current and CUR_MARK or ' ', is_current and 'VVGitPanelBranch' or 'Comment' }, { ' ' } }
    if BRANCH_ICON ~= '' then
      head[#head + 1] = { BRANCH_ICON, BRANCH_ICON_HL }
      head[#head + 1] = { ' ' }
    end
    head[#head + 1] = { ref_label(wt), wt.detached and 'WarningMsg' or (is_current and 'Title' or 'Normal') }

    local ref_end = 0
    for _, chunk in ipairs(head) do ref_end = ref_end + #chunk[1] end
    heads[index], ref_ends[index] = head, ref_end
    head_width = math.max(head_width, Rows.width(head))

    paths[index] = { { tilde(wt.path), 'Comment' } }
    if wt.prunable then
      tags[index] = { { '  (prunable)', 'DiagnosticError' } }
    elseif wt.locked then
      tags[index] = { { '  (locked)', 'DiagnosticWarn' } }
    else
      tags[index] = {}
    end
  end

  local cells = {}
  for index in ipairs(list) do
    local path = paths[index]
    if max_width then
      -- 同一父目录下的 worktree 靠路径末尾区分，从左侧截断保留尾部
      path = Rows.truncate(path, max_width - head_width - COLUMN_GAP - Rows.width(tags[index]), { side = 'left' })
    end
    cells[index] = { heads[index], vim.list_extend(path, tags[index]) }
  end

  local items = {}
  for index, chunks in ipairs(Rows.table(cells, { gap = COLUMN_GAP })) do
    items[index] = {
      id = list[index].path,
      row = { chunks = chunks },
      data = {
        wt = list[index],
        current = vim.fs.normalize(list[index].path) == root,
        ref_end = ref_ends[index],
      },
    }
  end
  return items
end

---@param state table
---@param on_select fun(wt: VVGitWorktree)
---@param config table?
function M.open_manager(state, on_select, config)
  if not state.git_root then return end
  local root = vim.fs.normalize(state.git_root)

  local view ---@type VVUIViewHandle?
  local list = {} ---@type VVGitWorktree[]
  local items = {} ---@type VVUIViewItem[] 最近一次重绘的条目，供删除 spinner 回查
  local layout_root = root
  local refresh_id = 0
  local action_scope = Async.scope({ cancel_previous = true })
  local manager_closed = false
  local owner_generation = State.root_generation(state)
  local lifecycle_ids = {}

  local function is_active()
    if manager_closed then return false end
    if state.git_root ~= root or state._closing then return false end
    if State.root_generation(state) ~= owner_generation then return false end
    -- 测试和外部调用方可能只提供 `{ git_root = ... }`；仅完整打开的 vv-git state 强制单例身份
    if state.tabpage and State.has() and not State.is_current(state) then return false end
    -- 首次列表到达前浮窗尚未打开；打开后以窗口仍在为准
    return not view or view.is_open()
  end

  local function close()
    if manager_closed then return end
    manager_closed = true
    action_scope:cancel()
    for _, id in ipairs(lifecycle_ids) do pcall(vim.api.nvim_del_autocmd, id) end
    lifecycle_ids = {}
    if view then view.close() end
  end

  if state.tabpage then
    lifecycle_ids[#lifecycle_ids + 1] = vim.api.nvim_create_autocmd('TabClosed', {
      callback = function()
        if not vim.api.nvim_tabpage_is_valid(state.tabpage) then close() end
      end,
    })
  end

  ---@return VVGitWorktree?
  local function selected()
    local item = view and view.item()
    return item and item.data.wt
  end

  local refresh

  local function choose()
    local wt = selected()
    if not wt or not is_active() then return end
    close()
    on_select(wt)
  end

  local function add()
    Create.run(root, layout_root, refresh, config, {
      is_active = is_active,
      begin = function() return action_scope:begin({ key = 'action' }) end,
      start_loading = function(label)
        if not view or not view.is_open() then return function() end end
        local handle = Loading.win_text({
          win = view.win,
          slot = 'title',
          label = label,
          format = function(frame, text) return (' %s · %s %s '):format(TITLE, frame, text) end,
        })
        return function() handle:stop() end
      end,
    })
  end

  local function remove()
    local wt = selected()
    if not wt or not view then return end
    local manager = view
    Remove.run(root, wt, refresh, {
      is_active = is_active,
      begin = function() return action_scope:begin({ key = 'action' }) end,
      start_loading = function()
        -- 帧贴在分支名后；列表刷新后按 path 重新定位，找不到（已被移除 / manager 失效）即隐藏
        local handle = Loading.mark({
          buf = manager.buf,
          get_pos = function()
            if not is_active() then return nil end
            local line, col = manager.pos_of(wt.path)
            if not line then return nil end
            for _, item in ipairs(items) do
              if item.id == wt.path then return { row = line, col = col + item.data.ref_end } end
            end
          end,
        })
        return function() handle:stop() end
      end,
    })
  end

  local actions = {
    { key = { '<CR>', 'l', '<Right>' }, desc = 'Switch', run = choose },
    { key = 'a', desc = 'Add', run = add },
    { key = 'd', desc = 'Remove', run = remove },
    { key = 'r', desc = 'Refresh', run = function() refresh() end },
    { key = '?', desc = 'Help', run = function(current)
      require('vv-utils.help_panel').open({
        source_buf = current.buf,
        desc_prefix = DESC_PREFIX .. ': ',
        actions = {
          Switch = { cat = 'Worktree', icon = BRANCH_ENTRY.glyph or '', icon_hl = BRANCH_ENTRY.hl },
          Add = { cat = 'Worktree', icon = ADD_ENTRY.glyph or '', icon_hl = ADD_ENTRY.hl },
          Remove = { cat = 'Worktree', icon = REMOVE_ENTRY.glyph or '', icon_hl = REMOVE_ENTRY.hl },
          Refresh = { cat = 'View', icon = REFRESH_ICON, icon_hl = 'MiniIconsCyan' },
          Help = { cat = 'View', icon = HELP_ENTRY.glyph or '', icon_hl = HELP_ENTRY.hl },
          Close = { cat = 'View', icon = CLOSE_ENTRY.glyph or '', icon_hl = CLOSE_ENTRY.hl },
        },
        categories = { 'Worktree', 'View' }, title = 'worktree keymaps',
        title_icon = BRANCH_ICON, title_icon_hl = BRANCH_ICON_HL, filetype = 'vv-git-worktree-help',
      })
    end },
  }
  local close_keys = require('vv-git.remote_esc').close_keys()

  local function focus_current()
    for _, item in ipairs(items) do
      if item.data.current then return view.focus(item.id) end
    end
  end

  local function open_view()
    view = UIView.open({
      title = TITLE,
      width = 'content',
      height = 'content',
      min_width = MIN_WIDTH,
      filetype = 'vv-git-worktree',
      desc_prefix = DESC_PREFIX,
      expand_key = false,
      section_keys = false,
      close_keys = close_keys,
      actions = actions,
      page = function(view)
        -- 窗口宽度随内容而定，不能拿它反过来截断内容；按视图给出的上限截断路径，
        -- 终端缩窄后状态标签仍可见
        items = build_items(list, root, view.item_width())
        return { sections = { { id = 'worktrees', items = items } } }
      end,
      on_close = close,
    })
    -- 首次打开落在当前 worktree 上；之后的刷新由 ui_view 按条目 id 保持光标
    focus_current()
  end

  ---@param next_list VVGitWorktree[]?
  ---@param err string?
  local function render(next_list, err)
    if not is_active() then return end
    if not next_list or #next_list == 0 then
      vim.notify('[vv-git] ' .. (err or 'No worktrees'), vim.log.levels.WARN)
      close()
      return
    end

    for _, wt in ipairs(next_list) do
      if wt.is_main and not wt.bare then layout_root = vim.fs.normalize(wt.path); break end
    end

    local manageable = vim.tbl_filter(function(wt) return not wt.bare end, next_list)
    if #manageable == 0 then
      vim.notify('[vv-git] No manageable worktree (bare repo only)', vim.log.levels.WARN)
      close()
      return
    end

    local previous = view and view.item()
    list = manageable
    if not view then return open_view() end

    view.refresh()
    -- 光标所在条目已不在列表里（如刚被删除）时回到当前 worktree，而不是列表顶部
    if not previous or not view.line_of(previous.id) then focus_current() end
  end

  refresh = function()
    if manager_closed then return end
    refresh_id = refresh_id + 1
    local request = refresh_id
    Git.worktree_list(root, function(next_list, err)
      if request ~= refresh_id or not is_active() then return end
      render(next_list, err)
    end)
  end

  refresh()
end

return M
