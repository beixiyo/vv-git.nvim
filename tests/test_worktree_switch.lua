-- Worktree 切换仅在 tab-local cwd 成功变更后提交到状态

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
assert(state.git_root == new_root, '成功 tcd 后新 root 已提交')
assert(vim.uv.fs_realpath(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(state.tabpage)))
    == vim.uv.fs_realpath(new_root), '切换仅影响目标 tab 的 cwd')
assert(vim.uv.fs_realpath(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(source_tab)))
    == vim.uv.fs_realpath(old_root), '切换保留发起 tab 的 cwd')
assert(state._reloaded == true, '成功切换会重载新 root')

state.git_root = old_root
state._reloaded = nil
vim.cmd('tabnew')
local invalid_tab = vim.api.nvim_get_current_tabpage()
vim.cmd('tabclose')
state.tabpage = invalid_tab
commands._worktree_pick()
assert(state.git_root == old_root, 'tablocal tcd 失败时保持旧 root')
assert(state._reloaded == nil, '失败切换不会重载未提交上下文')

Worktree.open_manager = original_open_manager
Loader.reload_index = original_reload
State.clear()
if vim.api.nvim_tabpage_is_valid(target_tab) then
  vim.api.nvim_set_current_tabpage(target_tab)
  vim.cmd('tabclose')
end
vim.fn.delete(tmp, 'rf')
print('PASS: vv-git 工作区切换')
