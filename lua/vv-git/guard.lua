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
-- 生命周期：M.open() → install；TabClosed → uninstall。仅在 vv-git tab 存活期间
-- 影响 nvim_open_win；关闭 tab 后全局 API 还原，对其它插件零残留

local State = require('vv-git.state')

local M = {}

-- 存 install 前的实现；非 nil 即"已劫持"。链式兼容：若别的插件已 patch 过
-- nvim_open_win，我们保存的是他们包装后的版本，uninstall 时还原到他们那层
---@type fun(buf:integer, enter:boolean, cfg:table):integer?
local orig_open_win = nil

-- 只摘会让新窗口进 diff-group 的三个选项。foldmethod/foldexpr/winhighlight
-- 即便被继承也不会影响 diff 计算（它们只是展示/折叠层），不必动
local OPTS = { 'diff', 'scrollbind', 'cursorbind' }

---@param win integer
local function sanitize(win)
  for _, opt in ipairs(OPTS) do
    pcall(vim.api.nvim_set_option_value, opt, false, { win = win })
  end
end

---@param buf integer
---@param enter boolean
---@param cfg table
---@return integer win
local function patched(buf, enter, cfg)
  local win = orig_open_win(buf, enter, cfg)

  local state = State._state
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

---@return boolean installed_now  本次调用是否真的做了 install（幂等：已安装返回 false）
function M.install()
  if orig_open_win ~= nil then return false end
  orig_open_win = vim.api.nvim_open_win
  vim.api.nvim_open_win = patched
  return true
end

---@return boolean uninstalled_now
function M.uninstall()
  if orig_open_win == nil then return false end
  vim.api.nvim_open_win = orig_open_win
  orig_open_win = nil
  return true
end

---@return boolean
function M.is_installed() return orig_open_win ~= nil end

return M
