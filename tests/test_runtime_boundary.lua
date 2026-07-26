-- Runtime ownership regression checks.
-- Run: nvim --headless -u NONE -l tests/test_runtime_boundary.lua

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
vim.api.nvim_open_win = original_open_win
assert(Guard.uninstall(), 'guard releases its snapshot')
assert(
  vim.api.nvim_open_win == original_open_win,
  'guard uninstall preserves a newer global nvim_open_win owner'
)

print('vv-git runtime boundary: PASS')
