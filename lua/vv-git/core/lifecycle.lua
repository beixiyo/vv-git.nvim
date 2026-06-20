-- tab 生命周期：open / close / toggle / toggle_panel / refresh / ensure_invariant

local State = require('vv-git.state')
local Panel = require('vv-git.left.panel')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Loader = require('vv-git.loader')
local Guard = require('vv-git.guard')
local Keymaps = require('vv-git.core.keymaps')
local Subrepo = require('vv-git.subrepo')
local Fs = require('vv-utils.fs')
local UGit = require('vv-utils.git')

local PERSIST_FILE = vim.fs.joinpath(vim.fn.stdpath('data'), 'vv-git.json')

---@return string? git_root
local function detect_git_root()
  return UGit.root()
end

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

---@param M table
function L.attach(M)
  function M.open()
    if State.has() then
      local s = State.get()
      if s.tabpage and vim.api.nvim_tabpage_is_valid(s.tabpage) then
        local rel_path = get_current_relpath(s.git_root)
        vim.api.nvim_set_current_tabpage(s.tabpage)
        if rel_path then
          s.cur_path = rel_path
          ensure_unfolded(s, rel_path)
          LeftRender.render(s)
        end
        if s.panel and s.panel.win and vim.api.nvim_win_is_valid(s.panel.win) then
          vim.api.nvim_set_current_win(s.panel.win)
        end
        return
      end
      State.clear()
    end

    local root = detect_git_root()
    if not root then
      vim.notify('[vv-git] Not a git repository', vim.log.levels.WARN)
      return
    end

    local rel_path = get_current_relpath(root)
    local prev_tab = vim.api.nvim_get_current_tabpage()

    vim.cmd('tab split')
    local tabpage = vim.api.nvim_get_current_tabpage()
    local main_win = vim.api.nvim_get_current_win()
    require('vv-utils.ui_window').show_chrome(main_win)

    local panel_buf = Panel.create_buf()
    Panel.open_split(panel_buf, { width = M._config.width })
    local panel_win = vim.api.nvim_get_current_win()

    local state = State.get()
    state.tabpage = tabpage
    state.prev_tab = prev_tab
    state.git_root = root
    state.cur_path = rel_path
    -- 把子仓库扫描深度/配置以闭包注入 state，避免数据层 loader 反向 require 顶层 init
    -- （闭包读 M 的实时值：:VVGitSubrepoDepth 改 override 后下次 reload 即生效）
    state._subrepo = {
      depth = M.get_subrepo_depth,
      config = function() return M._config.subrepo or {} end,
    }
    ensure_unfolded(state, rel_path)
    state.panel = {
      buf = panel_buf,
      win = panel_win,
      main_win = main_win,
    }
    state._panel_width = M._config.width

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
          s._panel_width = vim.api.nvim_win_get_width(s.panel.win)
        end
      end,
    })

    Keymaps.install(state, M)
    Guard.install()
    Loader.reload_index(state)
    M._apply_layout()
  end

  M.close = State.guarded(function(state)
    if state._panel_width then
      M._config.width = state._panel_width
      Fs.save_json(PERSIST_FILE, { width = state._panel_width })
    end

    local tp = state.tabpage
    local prev_tab = state.prev_tab

    if tp and vim.api.nvim_tabpage_is_valid(tp) and #vim.api.nvim_list_tabpages() == 1 then
      vim.notify('[vv-git] This is the only tab. Closing it will exit nvim. Please open a new tab first.', vim.log.levels.WARN)
      return
    end

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
      State.clear()
    end
  end)

  M._ensure_invariant = State.guarded(function(state)
    local panel_visible = state.panel
      and state.panel.win
      and vim.api.nvim_win_is_valid(state.panel.win)
    local view_active = state.view ~= nil
    if not (panel_visible or view_active) then
      vim.schedule(function() M.close() end)
    end
  end)

  function M.toggle()
    if State.has() then
      local s = State.get()
      if s.tabpage and vim.api.nvim_tabpage_is_valid(s.tabpage) then
        M.close()
        return
      end
    end
    M.open()
  end

  M.toggle_panel = State.guarded(function(state)
    if state.tabpage ~= vim.api.nvim_get_current_tabpage() then return end
    if not state.panel or not state.panel.buf then return end

    local win = state.panel.win
    local visible = win and vim.api.nvim_win_is_valid(win)

    if visible then
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
      Panel.open_split(state.panel.buf, { width = state._panel_width or M._config.width })
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
  end)
end

return L
