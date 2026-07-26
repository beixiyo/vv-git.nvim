-- vv-git panel width state integration
-- Run: nvim --headless -u NONE -l tests/test_panel_state.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local values = { width = 'invalid' }
local handle = {
  get = function(_, field, default)
    local value = values[field]
    return value == nil and default or value
  end,
  set = function(_, field, value)
    values[field] = value
    return true
  end,
}

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
vim.fn.system({ 'git', '-C', tmp, 'init', '--quiet' })

local git = require('vv-git')
git.setup({
  state = handle,
  width = 31,
  auto_refresh = false,
  preview = false,
  keymap_toggle_panel = false,
})

assert(git.open({ root = tmp }), 'vv-git should open in a temporary repository')
assert(vim.api.nvim_win_get_width(0) == 31, 'invalid persisted width should fall back to config')

vim.cmd('vertical resize 43')
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(250, function() return values.width == 43 end)
assert(values.width == 43, 'real :vertical resize should persist after debounce')

vim.cmd('tabclose')
vim.wait(100, function() return not git.is_open() end)
assert(values.width == 43, 'direct :tabclose should flush the latest panel width')

vim.fn.delete(tmp, 'rf')
print('vv-git panel state: PASS')
