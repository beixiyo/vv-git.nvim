-- 修 bug：第三方插件（noice cmdline、which-key、blink.cmp、notify 等）在 vv-git
-- 的 diff 窗口（a_win / b_win）上调 vim.api.nvim_open_win 创建浮窗时，新浮窗会
-- **继承** current win 的 win-local 选项（含 diff=true），被 nvim 的隐式 diff-group
-- 纳入成员：b_win 和"空内容浮窗"配对 xdiff → 整片标红；若多次触发会堆到
--   E96: Cannot diff more than 8 buffers
--
-- 为什么不靠 autocmd（WinNew / CmdlineEnter）：
--   1. 部分插件用 nvim_open_win({ noautocmd = true }) → WinNew 根本不触发
--   2. 即使触发，若用 vim.schedule 延迟清 diff，nvim 已完成一次渲染，污染已发生
-- 所以必须同步拦在 nvim_open_win 返回前把 diff 关掉 → 劫持 API 本身
--
-- 生命周期：M.open() → install；TabClosed → uninstall。卸载时若本层仍位于栈顶就
-- 摘除；若已有后装 wrapper 持有本层，则把闭包停用为透明转发，保持调用链可用

local State = require('vv-git.state')

local M = {}

-- 只摘会让新窗口进 diff-group 的三个选项。foldmethod/foldexpr/winhighlight
-- 即便被继承也不会影响 diff 计算（它们只是展示/折叠层），不必动
---@param win integer
local function sanitize(win)
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd('noautocmd setlocal nodiff noscrollbind nocursorbind')
  end)
end

---@class VVGitOpenWinGuardLayer
---@field upstream fun(buf:integer, enter:boolean, cfg:table):integer
---@field active boolean
---@field call fun(buf:integer, enter:boolean, cfg:table):integer

---@type VVGitOpenWinGuardLayer?
local installed_layer
local open_observers = {}
local next_observer_id = 0

---@param buf integer
---@param win integer
local function publish_open(buf, win)
  local matched = {}
  for id, observer in pairs(open_observers) do
    if observer.buf == buf then
      open_observers[id] = nil
      matched[#matched + 1] = observer.callback
    end
  end
  for _, callback in ipairs(matched) do pcall(callback, win) end
end

---@param upstream fun(buf:integer, enter:boolean, cfg:table):integer
---@return VVGitOpenWinGuardLayer
local function create_layer(upstream)
  local layer = { upstream = upstream, active = true }

  layer.call = function(buf, enter, cfg)
    local win = upstream(buf, enter, cfg)
    publish_open(buf, win)
    if not layer.active then return win end

    -- file_compare 使用 noautocmd 创建普通分屏，并自行持有 diff 配置。若在 API
    -- 返回后再清理，会把副作用重新带到受控挂载事务之外
    if vim.api.nvim_buf_is_valid(buf)
        and vim.b[buf].vv_git_file_compare_ref_pending then
      return win
    end

    local state = State.current()
    if not state or not state.tabpage then return win end
    if not vim.api.nvim_win_is_valid(win) then return win end

    -- 新浮窗必须落在 vv-git 专属 tab 内；其它 tab 的 open_win 原样放行
    local ok, tp = pcall(vim.api.nvim_win_get_tabpage, win)
    if not ok or tp ~= state.tabpage then return win end

    -- 豁免己方三窗：panel / a_win / b_win
    local view = state.view
    local is_mine = (state.panel and state.panel.win == win)
      or (view and (view.a_win == win or view.b_win == win))
    if is_mine then return win end

    sanitize(win)
    return win
  end

  return layer
end

---@return boolean installed_now  本次调用是否真的做了 install（幂等：已安装返回 false）
function M.install()
  if installed_layer and installed_layer.active then return false end
  local layer = create_layer(vim.api.nvim_open_win)
  installed_layer = layer
  vim.api.nvim_open_win = layer.call
  return true
end

---@return boolean uninstalled_now
function M.uninstall()
  local layer = installed_layer
  if not layer or not layer.active then return false end
  layer.active = false
  if vim.api.nvim_open_win == layer.call then
    vim.api.nvim_open_win = layer.upstream
  end
  -- 外层 wrapper 可能仍持有 layer.call；闭包保留不可变 upstream，并在停用后
  -- 变为透明转发层
  installed_layer = nil
  return true
end

---@return boolean
function M.is_installed() return installed_layer ~= nil and installed_layer.active end

---@param opts {buf:integer, callback:fun(win:integer)}
---@return fun() dispose
function M.observe_open(opts)
  if not M.is_installed() then return function() end end
  next_observer_id = next_observer_id + 1
  local id = next_observer_id
  open_observers[id] = { buf = opts.buf, callback = opts.callback }
  return function() open_observers[id] = nil end
end

return M
