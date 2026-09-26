-- 远程会话下不绑定关闭 / 取消类 <Esc>
--
-- SSH 链路可能把一次鼠标点击的 SGR 转义序列（ESC [ < b ; x ; y M）拆成两段送达，间隔超过
-- 'ttimeoutlen' 时 nvim 把开头的 ESC 当成独立 <Esc>：绑定了 <Esc> 关闭的面板会被误关，
-- 余下的 `[<0;x;yM` 再被当普通按键打进来。远程时这些面板只保留 q
--
-- 判定用 vv-utils.sys.is_remote（本机 tmux 被 SSH attach 也算远程）。结果缓存：首次按需
-- 同步检测；此后每次 FocusGained（远程 attach 进来切到 pane 时会触发）在后台异步重测，
-- 变化时通知订阅者（已打开的面板 / 右栏），由它们重装或卸掉 <Esc>

local Sys = require('vv-utils.sys')

local M = {}

---@type boolean?
local enabled
local checking = false
---@type table<integer, fun(enabled: boolean)>
local listeners = {}
local next_id = 0

--- 当前是否绑定关闭类 <Esc>（本地会话 true，远程会话 false）
---@return boolean
function M.enabled()
  if enabled == nil then enabled = not Sys.is_remote() end
  return enabled
end

--- 关闭 / 取消类映射应使用的按键
---@return string[]
function M.close_keys()
  return M.enabled() and { 'q', '<Esc>' } or { 'q' }
end

--- 订阅远程状态变化（只在结果真的改变时回调）
---@param fn fun(enabled: boolean)
---@return fun() unsubscribe
function M.subscribe(fn)
  next_id = next_id + 1
  local id = next_id
  listeners[id] = fn
  return function() listeners[id] = nil end
end

vim.api.nvim_create_autocmd('FocusGained', {
  group = vim.api.nvim_create_augroup('VVGitRemoteEsc', { clear = true }),
  callback = function()
    -- 从未检测过：等真正需要时再同步检测，不在这里白跑
    if enabled == nil or checking then return end
    checking = true
    Sys.is_remote_async(function(remote)
      checking = false
      local next_enabled = not remote
      if next_enabled == enabled then return end
      enabled = next_enabled
      for _, fn in pairs(listeners) do pcall(fn, enabled) end
    end)
  end,
})

return M
