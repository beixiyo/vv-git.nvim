-- Worktree manager integration: real Git add/remove safeguards plus the single-worktree UI entry

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Git = require('vv-git.git')
local Worktree = require('vv-git.worktree')
local VVGit = require('vv-git')
local tmp = vim.fn.tempname()
local repo = tmp .. '/repo'
local linked = tmp .. '/repo-feature'
vim.fn.mkdir(repo, 'p')

local function command(args)
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr or table.concat(args, ' '))
end

local function await(register)
  local done, values = false, nil
  register(function(...)
    values = { ... }
    done = true
  end)
  assert(vim.wait(5000, function() return done end, 10), 'async Git operation timed out')
  return unpack(values or {})
end

command({ 'git', '-C', repo, 'init', '-b', 'main' })
command({ 'git', '-C', repo, 'config', 'user.email', 'vv-git@example.invalid' })
command({ 'git', '-C', repo, 'config', 'user.name', 'vv-git test' })
vim.fn.writefile({ 'initial' }, repo .. '/tracked.txt')
command({ 'git', '-C', repo, 'add', 'tracked.txt' })
command({ 'git', '-C', repo, 'commit', '-m', 'initial' })

VVGit.setup({ auto_refresh = false, preview = false, keymap_toggle_panel = false })
local worktree_config = VVGit.config().worktree
assert(type(worktree_config.path) == 'function', 'worktree path resolver is public configuration')
assert(
  worktree_config.path(repo, 'feature/new-ui') == repo .. '/.worktrees/new-ui',
  'default worktree path follows the .worktrees branch-short convention'
)
assert(vim.api.nvim_get_hl(0, { name = 'VVGitWorktreeFooterKey' }).link ~= nil, 'footer key highlight is registered')
assert(vim.api.nvim_get_hl(0, { name = 'VVGitWorktreeFooterText' }).link ~= nil, 'footer text highlight is registered')
local Highlights = require('vv-git.hl')
Highlights.setup({ highlights = { VVGitPanelBranch = { fg = '#111111' } } })
Highlights.setup({ highlights = { VVGitPanelBranch = { fg = '#222222' } } })
assert(
  vim.api.nvim_get_hl(0, { name = 'VVGitPanelBranch', link = false }).fg == 0x222222,
  'explicit highlight overrides replace existing non-diff groups across setup calls'
)
Highlights.setup({ highlights = { VVGitAdded = { bold = true } } })
local shared_override = vim.api.nvim_get_hl(0, { name = 'VVGitAdded', link = false })
assert(shared_override.fg == 0x81b88b and shared_override.bold == true, 'shared highlight override keeps its baseline color')
Highlights.setup({ highlights = { VVGitAdded = { italic = true } } })
shared_override = vim.api.nvim_get_hl(0, { name = 'VVGitAdded', link = false })
assert(
  shared_override.fg == 0x81b88b and shared_override.bold ~= true and shared_override.italic == true,
  'repeated setup rebuilds shared highlights without stale user attributes'
)
Highlights.setup({ highlights = {} })
shared_override = vim.api.nvim_get_hl(0, { name = 'VVGitAdded', link = false })
assert(
  shared_override.fg == 0x81b88b and shared_override.bold ~= true and shared_override.italic ~= true,
  'removing a shared highlight override restores its static baseline'
)
assert(
  vim.api.nvim_get_hl(0, { name = 'VVGitPanelBranch' }).link == 'Keyword',
  'removing a linked highlight override restores its default link'
)

Worktree.open_manager({ git_root = repo }, function() end)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
end, 10), 'manager opens even when only the main worktree exists')
local manager_buf = vim.api.nvim_get_current_buf()
assert(#vim.api.nvim_buf_get_lines(manager_buf, 0, -1, false) == 1, 'single main worktree is rendered')
local mappings = vim.api.nvim_buf_get_keymap(manager_buf, 'n')
local actions = {}
for _, mapping in ipairs(mappings) do actions[mapping.desc or ''] = true end
assert(actions['vv-git-worktree: add'], 'manager exposes add')
assert(actions['vv-git-worktree: remove'], 'manager exposes remove')
assert(type(vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).footer) == 'table', 'footer uses highlight chunks')
vim.api.nvim_feedkeys('r', 'x', false)
vim.wait(100, function() return false end, 10)
assert(vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()), 'manager refresh keeps the floating window valid')
assert(#vim.api.nvim_buf_get_lines(manager_buf, 0, -1, false) == 1, 'manager refresh renders the worktree list')
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)

local added, add_err = await(function(cb)
  Git.worktree_add(repo, { path = linked, base = 'main', branch = 'feature' }, cb)
end)
assert(added, add_err or 'worktree add failed')
assert(vim.fn.isdirectory(linked) == 1, 'worktree add creates the checkout directory')

-- 从 linked worktree 创建时，默认布局仍锚定 main worktree，而不是嵌套到当前 checkout。
local original_select, original_input = vim.ui.select, vim.ui.input
local suggested_path
vim.ui.select = function(items, opts, cb)
  if opts.prompt == 'Create worktree:' then
    cb('New branch')
  elseif opts.prompt == 'Base ref:' then
    cb('main')
  else
    cb(items[1])
  end
end
vim.ui.input = function(opts, cb)
  if opts.prompt == 'New branch: ' then
    cb('bugfix/new-ui')
  elseif opts.prompt == 'Worktree path: ' then
    suggested_path = opts.default
    cb(nil)
  end
end
Worktree.open_manager({ git_root = linked }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
end, 10), 'manager opens from a linked worktree')
vim.api.nvim_feedkeys('a', 'x', false)
assert(vim.wait(5000, function() return suggested_path ~= nil end, 10), 'create flow reaches the path prompt')
assert(suggested_path == vim.uv.fs_realpath(repo) .. '/.worktrees/new-ui',
  'linked worktree creation uses the main worktree layout root')
vim.ui.select, vim.ui.input = original_select, original_input
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)

-- Manager 打开后再被外部 lock：普通 remove 失败后必须重读状态，不能提供 force 绕过。
Worktree.open_manager({ git_root = repo }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
    and #vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false) == 2
end, 10), 'manager renders the linked worktree before the lock race')
command({ 'git', '-C', repo, 'worktree', 'lock', linked })
local original_confirm = vim.fn.confirm
local confirm_count = 0
vim.fn.confirm = function()
  confirm_count = confirm_count + 1
  return 1
end
vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
vim.api.nvim_feedkeys('d', 'x', false)
vim.wait(300, function() return false end, 10)
assert(vim.fn.isdirectory(linked) == 1, 'a worktree locked after render is preserved')
assert(confirm_count == 1, 'locked removal race never offers force confirmation')
vim.fn.confirm = original_confirm
command({ 'git', '-C', repo, 'worktree', 'unlock', linked })
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)

vim.fn.writefile({ 'dirty' }, linked .. '/dirty.txt')
local removed = await(function(cb) Git.worktree_remove(repo, linked, nil, cb) end)
assert(not removed, 'normal removal refuses a dirty worktree')
assert(vim.fn.isdirectory(linked) == 1, 'failed normal removal preserves the directory')

local dirty, dirty_err = await(function(cb) Git.worktree_dirty(linked, cb) end)
assert(dirty == true, dirty_err or 'dirty worktree is detected before force removal')
Worktree.open_manager({ git_root = repo }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
    and #vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false) == 2
end, 10), 'manager renders the dirty worktree')
confirm_count = 0
original_confirm = vim.fn.confirm
vim.fn.confirm = function()
  confirm_count = confirm_count + 1
  return 1
end
vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
vim.api.nvim_feedkeys('d', 'x', false)
assert(vim.wait(5000, function() return vim.fn.isdirectory(linked) == 0 end, 10), 'confirmed dirty removal deletes the checkout')
assert(confirm_count == 2, 'dirty removal requires normal and force confirmations')
vim.fn.confirm = original_confirm

vim.fn.delete(tmp, 'rf')
print('vv-git worktree manager: PASS')
