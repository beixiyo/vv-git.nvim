-- tab 生命周期：open / close / toggle / toggle_panel / refresh / ensure_invariant

local State = require('vv-git.state')
local Panel = require('vv-git.left.panel')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Loader = require('vv-git.loader')
local Guard = require('vv-git.guard')
local Keymaps = require('vv-git.core.keymaps')
local Subrepo = require('vv-git.subrepo')
local UGit = require('vv-utils.git')

---@param root string
---@return string? relpath
local function get_current_relpath(root)
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or not root then return nil end
  name = vim.fs.normalize(name)
  if name:sub(1, #root + 1) == root .. '/' then
    local rel = name:sub(#root + 2)
    if rel ~= "" then return rel end
  end
  return nil
end

---@param root string
---@param path string?
---@return string? relpath, string? err
local function resolve_relpath(root, path)
  if not path or path == '' then return get_current_relpath(root) end

  if path:sub(1, 1) ~= '/' then
    local absolute = vim.fs.normalize(root .. '/' .. path)
    if absolute ~= root and absolute:sub(1, #root + 1) ~= root .. '/' then
      return nil, 'path is outside the Git repository: ' .. path
    end
    return absolute ~= root and absolute:sub(#root + 2) or nil
  end

  local absolute = vim.fs.normalize(path)
  if absolute == root then return nil end
  if absolute:sub(1, #root + 1) ~= root .. '/' then
    return nil, 'path is outside the Git repository: ' .. absolute
  end
  return absolute:sub(#root + 2)
end

-- vv-explorer 最近一次切根（`]`/`[`）广播过来的目录，见 L.attach 里的 M._follow_external_root。
-- 面板关着时 open() 无从得知用户在 explorer 里已经换了仓库（它只会问 getcwd()），
-- 故在这里记一份，作为「无显式目标」时的首选候选根
local external_root = nil

-- 目录还在、且能解析出仓库根时才当候选；否则返回 nil 让调用方回退 getcwd()
---@return string?
local function external_candidate()
  if not external_root then return nil end
  if vim.fn.isdirectory(external_root) == 0 then
    external_root = nil
    return nil
  end
  return external_root
end

---@param opts VVGitOpenOpts
---@return string? root, string? relpath, string? err
local function resolve_open_context(opts)
  local candidate = opts.root
  if not candidate and opts.path and opts.path:sub(1, 1) == '/' then
    candidate = vim.fs.dirname(vim.fs.normalize(opts.path))
  end

  -- 显式 root/path 优先；都没有才跟随 explorer 切根
  local from_explorer = nil
  if not candidate and not opts.path then
    from_explorer = external_candidate()
    candidate = from_explorer
  end

  local root = UGit.root(candidate)
  -- explorer 停在非仓库目录（~/Downloads 之类）时不该报错，回退原来的 getcwd() 语义
  if not root and from_explorer then
    candidate = nil
    root = UGit.root(nil)
  end
  if not root then
    return nil, nil, 'not a Git repository' .. (candidate and (': ' .. candidate) or '')
  end

  local relpath, err = resolve_relpath(root, opts.path)
  if err then return nil, nil, err end
  return root, relpath
end

local function ensure_unfolded(state, relpath)
  if not relpath or not state.folds then return end
  local parts = vim.split(relpath, '/', { plain = true })
  local accum = ''
  for i = 1, #parts - 1 do
    accum = accum == '' and parts[i] or (accum .. '/' .. parts[i])
    for k, _ in pairs(state.folds) do
      -- relpath 相对父仓库根，只展开父仓库（root == nil）的 fold，
      -- 避免误伤子仓库里同名目录的折叠状态（跨仓库过度展开）
      local root, _, rel = Subrepo.parse_sel_key(k)
      if root == nil and rel == accum then
        state.folds[k] = nil
      end
    end
  end
end

-- 记录本模块注册的 WinResized autocmd id：每次 open 前先删旧的再注册，
-- 避免跨 open/close 循环线性累积（State.clear 不持有该 id，故存模块级 upvalue）
local resize_autocmd_id = nil

local L = {}

---@class VVGitLifecycleDeps
---@field controller table
---@field config fun():table
---@field track_panel_width fun(state:table)
---@field persist_panel_width fun(state:table)

---@param deps VVGitLifecycleDeps
---@return table
function L.new(deps)
  local M = {}
  local controller = deps.controller
  local function config() return deps.config() end
  ---@param opts? VVGitOpenOpts
  ---@return boolean opened, string? err
  function M.open(opts)
    opts = opts or {}

    if State.has() then
      local s = State.get()
      if s.tabpage and vim.api.nvim_tabpage_is_valid(s.tabpage) then
        local root, relpath, err
        if opts.root or opts.path then
          root, relpath, err = resolve_open_context(opts)
        else
          root, relpath = s.git_root, get_current_relpath(s.git_root)
        end
        if not root then
          vim.notify('[vv-git] ' .. err, vim.log.levels.WARN)
          controller._invoke_callback(opts.on_error, err)
          return false, err
        end

        if root == s.git_root then
          controller._register_on_close(s, opts.on_close)
          vim.api.nvim_set_current_tabpage(s.tabpage)
          if relpath then
            s.cur_path = relpath
            ensure_unfolded(s, relpath)
            LeftRender.render(s)
          end
          if s.panel and s.panel.win and vim.api.nvim_win_is_valid(s.panel.win) then
            vim.api.nvim_set_current_win(s.panel.win)
          end
          controller._invoke_callback(opts.on_ready, controller._context(s))
          return true
        end

        controller.close()
        if State.has() then
          local message = 'cannot switch vv-git to repository: ' .. root
          controller._invoke_callback(opts.on_error, message)
          return false, message
        end
      end
      State.clear()
    end

    local root, rel_path, err = resolve_open_context(opts)
    if not root then
      vim.notify('[vv-git] ' .. err, vim.log.levels.WARN)
      controller._invoke_callback(opts.on_error, err)
      return false, err
    end

    local resume_after_close
    if config().before_open then
      local ok, result = pcall(config().before_open)
      if not ok then
        vim.notify('[vv-git] before_open failed: ' .. tostring(result), vim.log.levels.ERROR)
        controller._invoke_callback(opts.on_error, tostring(result))
        return false, tostring(result)
      end
      if type(result) == 'function' then resume_after_close = result end
    end

    local prev_tab = vim.api.nvim_get_current_tabpage()

    vim.cmd('tab split')
    local tabpage = vim.api.nvim_get_current_tabpage()
    -- 约定：让自研 vv-bufferline 跳过整个 vv-git tab（panel/diff/冲突窗都不叠分屏标签栏）
    -- 同步在建 tab 后立刻标记，赶在 bufferline 的 scheduled refresh 之前，避免它先画一次再清
    pcall(vim.api.nvim_tabpage_set_var, tabpage, 'vv_bufferline_ignore', true)
    local main_win = vim.api.nvim_get_current_win()
    require('vv-utils.ui_window').show_chrome(main_win)

    local panel_buf = Panel.create_buf()
    Panel.open_split(panel_buf, { width = config().width })
    local panel_win = vim.api.nvim_get_current_win()

    local state = State.create()
    state.tabpage = tabpage
    state.prev_tab = prev_tab
    state.git_root = root
    state.cur_path = rel_path
    state._resume_after_close = resume_after_close
    -- 把子仓库扫描深度/配置以闭包注入 state，避免数据层 loader 反向 require 顶层 init
    -- （闭包读 M 的实时值：:VVGitSubrepoDepth 改 override 后下次 reload 即生效）
    state._subrepo = {
      depth = controller.get_subrepo_depth,
      config = function() return config().subrepo or {} end,
    }
    ensure_unfolded(state, rel_path)

    -- 配置项 fold_staged：打开面板时把父仓库的 Staged Changes section 默认折成标题行
    -- （仅此一层，section_id 用裸 'staged'；子仓库块的 staged 不受影响）。只在这条
    -- fresh-open 路径一次性写入 section_folds，用户之后可正常展开/折叠；重开面板（state
    -- 被 clear 后重建）才再次套用默认。toggle_panel / 复用已开面板都不会重置
    if config().fold_staged then
      state.section_folds = state.section_folds or {}
      state.section_folds[Subrepo.section_id(state.git_root, state.git_root, 'staged')] = true
      state._fold_staged_pending = true
    end

    state.panel = {
      buf = panel_buf,
      win = panel_win,
      main_win = main_win,
    }
    state._panel_width = config().width
    controller._register_on_close(state, opts.on_close)

    -- 先注销上一轮残留的注册，保证全局至多一个 WinResized 监听
    if resize_autocmd_id then
      pcall(vim.api.nvim_del_autocmd, resize_autocmd_id)
      resize_autocmd_id = nil
    end
    resize_autocmd_id = vim.api.nvim_create_autocmd('WinResized', {
      callback = function()
        if not State.has() then return true end
        local s = State.get()
        if s.panel and s.panel.win and vim.api.nvim_win_is_valid(s.panel.win) then
          deps.track_panel_width(s)
        end
      end,
    })

    Keymaps.install(state, controller)
    Guard.install()
    Loader.reload_index(state, function()
      controller._invoke_callback(opts.on_ready, controller._context(state))
    end)
    controller._apply_layout()
    return true
  end

  M.close = State.guarded(function(state)
    local tp = state.tabpage
    local prev_tab = state.prev_tab

    if tp and vim.api.nvim_tabpage_is_valid(tp) and #vim.api.nvim_list_tabpages() == 1 then
      vim.notify('[vv-git] This is the only tab. Closing it will exit nvim. Please open a new tab first.', vim.log.levels.WARN)
      return
    end

    deps.track_panel_width(state)
    deps.persist_panel_width(state)

    if tp and vim.api.nvim_tabpage_is_valid(tp) then
      pcall(function()
        local pagenr = vim.api.nvim_tabpage_get_number(tp)
        vim.cmd('tabclose ' .. pagenr)
      end)
      if prev_tab and vim.api.nvim_tabpage_is_valid(prev_tab) then
        pcall(vim.api.nvim_set_current_tabpage, prev_tab)
      end
    else
      pcall(RightView.close, state)
      controller._emit_closed(state)
      State.clear()
    end
    return true
  end)

  M._ensure_invariant = State.guarded(function(state)
    local panel_visible = state.panel
      and state.panel.win
      and vim.api.nvim_win_is_valid(state.panel.win)
    local view_active = state.view ~= nil
    if not (panel_visible or view_active) then
      vim.schedule(function() controller.close() end)
    end
  end)

  function M.toggle()
    if State.has() then
      local s = State.get()
      if s.tabpage and vim.api.nvim_tabpage_is_valid(s.tabpage) then
        controller.close()
        return true
      end
    end
    return M.open()
  end

  M.toggle_panel = State.guarded(function(state)
    if state.tabpage ~= vim.api.nvim_get_current_tabpage() then return end
    if not state.panel or not state.panel.buf then return end

    local win = state.panel.win
    local visible = win and vim.api.nvim_win_is_valid(win)

    if visible then
      deps.track_panel_width(state)
      deps.persist_panel_width(state)
      local main = state.panel.main_win
      if main and vim.api.nvim_win_is_valid(main) then
        pcall(vim.api.nvim_set_current_win, main)
      end
      -- 先置空再关窗：nvim_win_close 会同步触发 WinClosed，此时若 state.panel.win
      -- 仍指向旧窗口，handler 会标记 dirty 并同步调用 on_ensure_invariant；当尚未打开
      -- 任何 diff（state.view == nil）时不变式会误判整个 tab 无用而调度 close，
      -- 把「隐藏 panel」变成「关闭整个 vv-git tab」。先置空可让 handler 短路
      state.panel.win = nil
      state._panel_hidden = true
      Panel.close_win(win)
    else
      Panel.open_split(state.panel.buf, { width = state._panel_width or config().width })
      state.panel.win = vim.api.nvim_get_current_win()
      state._panel_hidden = false
      LeftRender.render(state)
    end
  end)

  -- 所有经 M.refresh 的刷新都是被动刷新（auto_refresh / BufWritePost / GitSignsChanged /
  -- 手动 R / commit-push）——语义是「更新列表，别动我光标」，故走 passive，render 保持光标
  -- 停在当前文件而非按滞后 cur_path 拉走（stage/unstage/discard 等带 _action_hint 的动作
  -- 不经 M.refresh，仍走 reload_index 非 passive 路径，落点逻辑不受影响）
  M.refresh = State.guarded(function(state)
    if not state.panel or not state.git_root then return end
    Loader.reload_index(state, nil, true)
    return true
  end)

  -- vv-explorer 按 `]`/`[` 切根后广播 User VVExplorerRootChanged → 这里跟随：
  --   * 面板关着：只记住目录，下次 open() 用它当候选根（见 resolve_open_context）
  --   * 面板开着：解析出仓库根，与当前 git_root 不同才切——同一仓库内部换目录不用动，
  --     status 本来就是整仓库范围的，重载只会白闪一次
  -- 切换语义与 _worktree_pick 对齐：清掉随旧 root 失效的瞬态（选中/比较/折叠/右视图）。
  -- 不 tcd：事件是在 explorer 所在 tab 触发的，tcd 会改错 tab 的目录
  ---@param dir string
  function M._follow_external_root(dir)
    if not dir or dir == '' then return end
    external_root = vim.fs.normalize(dir)

    if not State.has() then return end
    local state = State.get()
    if not state.panel or not state.git_root then return end

    UGit.root_async(external_root, function(root)
      -- 异步窗口期内面板可能已被关掉 / 重开成另一个 state
      if not State.is_current(state) then return end
      if not root or root == state.git_root then return end

      state.git_root = root
      state.cur_path = nil
      state.selection = {}
      state.folds = {}
      state.section_folds = {}
      state.block_folds = {}
      require('vv-git.compare').stop(state)
      RightView.close(state)
      Loader.reload_index(state)
    end)
  end
  return M
end

return L
