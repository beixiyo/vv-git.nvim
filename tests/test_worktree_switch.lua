-- Worktree switching commits state only after tab-local cwd changes successfully

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Commands = require('vv-git.core.commands')
local Loader = require('vv-git.loader')
local State = require('vv-git.state')
local Worktree = require('vv-git.worktree')

local tmp = vim.fn.tempname()
local old_root = tmp .. '/old'
local new_root = tmp .. '/new'
vim.fn.mkdir(old_root, 'p')
vim.fn.mkdir(new_root, 'p')

local original_open_manager = Worktree.open_manager
local original_reload = Loader.reload_index
Worktree.open_manager = function(_, on_select) on_select({ path = new_root }) end
Loader.reload_index = function(state) state._reloaded = true end

local commands = Commands.new({
  controller = {},
  config = function() return { worktree = {} } end,
})

State.clear()
local state = State.create()
state.git_root = old_root
local source_tab = vim.api.nvim_get_current_tabpage()
vim.cmd.tcd(vim.fn.fnameescape(old_root))
vim.cmd('tabnew')
local target_tab = vim.api.nvim_get_current_tabpage()
vim.cmd.tcd(vim.fn.fnameescape(old_root))
vim.api.nvim_set_current_tabpage(source_tab)
state.tabpage = target_tab
state.folds = {}
state.section_folds = {}
state.block_folds = {}
state.selection = {}
commands._worktree_pick()
assert(state.git_root == new_root, 'successful tcd commits the new root')
assert(vim.uv.fs_realpath(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(state.tabpage)))
    == vim.uv.fs_realpath(new_root), 'switch changes only the target tab cwd')
assert(vim.uv.fs_realpath(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(source_tab)))
    == vim.uv.fs_realpath(old_root), 'switch preserves the caller tab cwd')
assert(state._reloaded == true, 'successful switch reloads the new root')

state.git_root = old_root
state._reloaded = nil
vim.cmd('tabnew')
local invalid_tab = vim.api.nvim_get_current_tabpage()
vim.cmd('tabclose')
state.tabpage = invalid_tab
commands._worktree_pick()
assert(state.git_root == old_root, 'failed tab-local tcd preserves the old root')
assert(state._reloaded == nil, 'failed switch does not reload a half-committed context')

Worktree.open_manager = original_open_manager
Loader.reload_index = original_reload
State.clear()
if vim.api.nvim_tabpage_is_valid(target_tab) then
  vim.api.nvim_set_current_tabpage(target_tab)
  vim.cmd('tabclose')
end
vim.fn.delete(tmp, 'rf')
print('vv-git worktree switch: PASS')
