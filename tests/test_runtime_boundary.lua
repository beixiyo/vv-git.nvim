-- 运行时所有权回归检查
-- 运行：nvim --headless -u NONE -l tests/test_runtime_boundary.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local State = require('vv-git.state')
State.clear()
local first = State.create()
assert(State.current() == first, '创建会话应成为当前会话')
State.clear()
assert(State.current() == nil, 'clear 后应释放当前会话')
assert(not State.is_current(first), '已清理会话不能再次成为当前会话')
local second = State.create()
assert(second ~= first, '新会话应与已清理会话隔离')
State.clear()

local values = {}
local handle = {
  get = function(_, key) return values[key] end,
  set = function(_, key, value) values[key] = value end,
}
local git = require('vv-git')
git.setup({ state = handle, auto_refresh = false, preview = false, keymap_toggle_panel = false })
git.setup({ state = handle, auto_refresh = false, preview = false, keymap_toggle_panel = false })

local group = vim.api.nvim_create_augroup('VVGit', { clear = false })
local autocmds = vim.api.nvim_get_autocmds({ group = group })
local counts = {}
for _, autocmd in ipairs(autocmds) do
  local events = type(autocmd.event) == 'table' and autocmd.event or { autocmd.event }
  for _, event in ipairs(events) do counts[event] = (counts[event] or 0) + 1 end
end
assert((counts.TabClosed or 0) == 1, '重复 setup 时仅保留一个 TabClosed 监听')
assert((counts.WinClosed or 0) == 1, '重复 setup 时仅保留一个 WinClosed 监听')

local Guard = require('vv-git.guard')
Guard.uninstall()
local original_open_win = vim.api.nvim_open_win
assert(Guard.install(), 'guard 仅安装一次')
local guarded_open_win = vim.api.nvim_open_win
local outer_calls = 0
local function outer_open_win(...)
  outer_calls = outer_calls + 1
  return guarded_open_win(...)
end
vim.api.nvim_open_win = outer_open_win
assert(Guard.uninstall(), 'guard 释放其快照')
assert(
  vim.api.nvim_open_win == outer_open_win,
  'guard 卸载后应保留更新后的 outer nvim_open_win'
)
local wrapper_buf = vim.api.nvim_create_buf(false, true)
local wrapper_ok, wrapper_win = pcall(vim.api.nvim_open_win, wrapper_buf, false, {
  relative = 'editor',
  row = 0,
  col = 0,
  width = 1,
  height = 1,
  noautocmd = true,
})
assert(wrapper_ok and vim.api.nvim_win_is_valid(wrapper_win),
  'guard 卸载后外层包装仍可调用')
assert(outer_calls == 1, '禁用 guard 后外层包装仅通过该层委托一次')
vim.api.nvim_win_close(wrapper_win, true)

assert(Guard.install(), 'guard 可在外层包装上方重装且不递归')
assert(Guard.uninstall(), '重装的 guard 可从包装链顶部移除')
assert(vim.api.nvim_open_win == outer_open_win,
  '重装与卸载后应恢复外层包装链控制')
vim.api.nvim_open_win = original_open_win

local guard_state = State.create()
guard_state.tabpage = vim.api.nvim_get_current_tabpage()
local option_events = 0
local option_group = vim.api.nvim_create_augroup('VVGitGuardNoautocmdTest', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', {
  group = option_group,
  pattern = { 'diff', 'scrollbind', 'cursorbind' },
  callback = function() option_events = option_events + 1 end,
})
vim.cmd('diffthis')
option_events = 0
assert(Guard.install(), 'guard 在 noautocmd 浮窗测试中也应安装')
local float_buf = vim.api.nvim_create_buf(false, true)
local float_win = vim.api.nvim_open_win(float_buf, false, {
  relative = 'editor',
  row = 0,
  col = 0,
  width = 1,
  height = 1,
  noautocmd = true,
})
assert(option_events == 0, 'guard 应保留第三方 noautocmd 事件边界')
assert(not vim.wo[float_win].diff
    and not vim.wo[float_win].scrollbind
    and not vim.wo[float_win].cursorbind,
  'guard 仍应清理继承的 diff 等窗口选项')
vim.api.nvim_win_close(float_win, true)
Guard.uninstall()
vim.api.nvim_del_augroup_by_id(option_group)
vim.cmd('diffoff')
State.clear()

print('PASS: vv-git 运行时边界回归')
