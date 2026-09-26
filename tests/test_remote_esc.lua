-- 回归：SSH 远程会话下鼠标转义序列被拆包时，开头的 ESC 会被当成独立 <Esc>，误关 vv-git
-- 远程时面板 / 右栏不绑定 <Esc>（保留 q）；远程状态变化后 FocusGained 让已打开的 vv-git 跟随重装
-- 用法: cd vv-git.nvim && nvim --headless -u NONE -l tests/test_remote_esc.lua
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
local vendors_root = vim.fn.fnamemodify(plugin_root, ':h')

local paths = { plugin_root .. '/lua/?.lua', plugin_root .. '/lua/?/init.lua' }
for _, dir in ipairs(vim.fn.glob(vendors_root .. '/vv-*.nvim', false, true)) do
  paths[#paths + 1] = dir .. '/lua/?.lua'
  paths[#paths + 1] = dir .. '/lua/?/init.lua'
end
paths[#paths + 1] = package.path
package.path = table.concat(paths, ';')

-- 远程状态由测试控制：替换 vv-utils 的检测，不依赖真实 tmux / ssh 环境
local remote = true
local Sys = require('vv-utils.sys')
Sys.is_remote = function() return remote end
Sys.is_remote_async = function(callback) vim.schedule(function() callback(remote) end) end

local pass, fail = 0, 0
local function check(c, l)
  if c then pass = pass + 1; print('PASS: ' .. l) else fail = fail + 1; print('FAIL: ' .. l) end
end

local Plugin = require('vv-git')
local State = require('vv-git.state')

local function has_map(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if m.lhs == lhs then return true end
  end
  return false
end

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, 'p')
vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
vim.fn.writefile({ 'committed' }, tmpdir .. '/sample.txt')
vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'changed' }, tmpdir .. '/sample.txt')

Plugin.setup({ keymap_toggle_panel = false, auto_refresh = false, subrepo = { depth = 0 } })
local ready = false
Plugin.open({ root = tmpdir, path = 'sample.txt', on_ready = function() ready = true end })
vim.wait(3000, function() return ready end)

local state = State.get()
local panel_buf = state.panel.buf
require('vv-git.right.view').show(state, { is_dir = false, relpath = 'sample.txt', xy = ' M' }, 'unstaged', false, state.git_root)
check(vim.wait(3000, function() return state.view and state.view.b_buf ~= nil end), '右栏 diff 视图已打开')
local right_buf = state.view.b_buf

check(not has_map(panel_buf, '<Esc>'), '远程：面板不绑定 <Esc>')
check(has_map(panel_buf, 'q'), '远程：面板保留 q')
check(not has_map(right_buf, '<Esc>'), '远程：右栏不绑定 <Esc>')
check(has_map(right_buf, 'q'), '远程：右栏保留 q')

-- 远程客户端断开、回到本地：切回 nvim 后已打开的 vv-git 补上 <Esc>
remote = false
vim.api.nvim_exec_autocmds('FocusGained', {})
check(vim.wait(1000, function() return has_map(panel_buf, '<Esc>') end), '转为本地后 FocusGained：面板补绑 <Esc>')
check(has_map(right_buf, '<Esc>'), '转为本地后 FocusGained：右栏补绑 <Esc>')

-- 本机开着的 vv-git 被 SSH attach 复用：切到 pane 后卸掉 <Esc>
remote = true
vim.api.nvim_exec_autocmds('FocusGained', {})
check(vim.wait(1000, function() return not has_map(panel_buf, '<Esc>') end), '转为远程后 FocusGained：面板卸掉 <Esc>')
check(not has_map(right_buf, '<Esc>'), '转为远程后 FocusGained：右栏卸掉 <Esc>')
check(has_map(panel_buf, 'q') and has_map(right_buf, 'q'), '转为远程后 q 仍可关闭')

print(('== %d PASS / %d FAIL =='):format(pass, fail))
vim.cmd(fail > 0 and 'cquit 1' or 'qa!')
