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
assert(State.current() == first, 'create owns the current session')
State.clear()
assert(State.current() == nil, 'clear releases the current session')
assert(not State.is_current(first), 'cleared session cannot become current again')
local second = State.create()
assert(second ~= first, 'a new session is isolated from the cleared session')
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
assert((counts.TabClosed or 0) == 1, 'repeated setup keeps one TabClosed listener')
assert((counts.WinClosed or 0) == 1, 'repeated setup keeps one WinClosed listener')

local Guard = require('vv-git.guard')
Guard.uninstall()
local original_open_win = vim.api.nvim_open_win
assert(Guard.install(), 'guard installs once')
local guarded_open_win = vim.api.nvim_open_win
local outer_calls = 0
local function outer_open_win(...)
  outer_calls = outer_calls + 1
  return guarded_open_win(...)
end
vim.api.nvim_open_win = outer_open_win
assert(Guard.uninstall(), 'guard releases its snapshot')
assert(
  vim.api.nvim_open_win == outer_open_win,
  'guard uninstall preserves a newer outer nvim_open_win owner'
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
  'outer wrapper remains callable after guard uninstall')
assert(outer_calls == 1, 'outer wrapper delegates through the disabled guard layer exactly once')
vim.api.nvim_win_close(wrapper_win, true)

assert(Guard.install(), 'guard can reinstall above an outer wrapper without recursion')
assert(Guard.uninstall(), 'reinstalled guard can be removed from the top of the wrapper chain')
assert(vim.api.nvim_open_win == outer_open_win,
  'reinstall/uninstall returns control to the outer wrapper')
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
assert(Guard.install(), 'guard installs for noautocmd float test')
local float_buf = vim.api.nvim_create_buf(false, true)
local float_win = vim.api.nvim_open_win(float_buf, false, {
  relative = 'editor',
  row = 0,
  col = 0,
  width = 1,
  height = 1,
  noautocmd = true,
})
assert(option_events == 0, 'guard preserves a third-party noautocmd event boundary')
assert(not vim.wo[float_win].diff
    and not vim.wo[float_win].scrollbind
    and not vim.wo[float_win].cursorbind,
  'guard still sanitizes inherited diff options')
vim.api.nvim_win_close(float_win, true)
Guard.uninstall()
vim.api.nvim_del_augroup_by_id(option_group)
vim.cmd('diffoff')
State.clear()

print('vv-git runtime boundary: PASS')
