-- Worktree manager integration: real Git add/remove safeguards plus the single-worktree UI entry

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Git = require('vv-git.git')
local Confirm = require('vv-utils.confirm')
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
  assert(vim.wait(5000, function() return done end, 10), '异步 Git 操作超时')
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
assert(type(worktree_config.path) == 'function', 'worktree path resolver 为公开配置')
assert(
  worktree_config.path(repo, 'feature/new-ui') == repo .. '/.worktrees/new-ui',
  '默认 worktree path 遵循 .worktrees 的分支短名约定'
)
assert(vim.api.nvim_get_hl(0, { name = 'VVGitWorktreeFooterKey' }).link ~= nil, 'footer key 高亮应已注册')
assert(vim.api.nvim_get_hl(0, { name = 'VVGitWorktreeFooterText' }).link ~= nil, 'footer text 高亮应已注册')
local Highlights = require('vv-git.hl')
Highlights.setup({ highlights = { VVGitPanelBranch = { fg = '#111111' } } })
Highlights.setup({ highlights = { VVGitPanelBranch = { fg = '#222222' } } })
assert(
  vim.api.nvim_get_hl(0, { name = 'VVGitPanelBranch', link = false }).fg == 0x222222,
  '显式高亮覆写应跨 setup 替换已有非 diff 分组'
)
Highlights.setup({ highlights = { VVGitAdded = { bold = true } } })
local shared_override = vim.api.nvim_get_hl(0, { name = 'VVGitAdded', link = false })
assert(shared_override.fg == 0x81b88b and shared_override.bold == true, '共享高亮覆写应保留基线颜色')
Highlights.setup({ highlights = { VVGitAdded = { italic = true } } })
shared_override = vim.api.nvim_get_hl(0, { name = 'VVGitAdded', link = false })
assert(
  shared_override.fg == 0x81b88b and shared_override.bold ~= true and shared_override.italic == true,
  '重复 setup 不应保留过期用户属性地重建共享高亮'
)
Highlights.setup({ highlights = {} })
shared_override = vim.api.nvim_get_hl(0, { name = 'VVGitAdded', link = false })
assert(
  shared_override.fg == 0x81b88b and shared_override.bold ~= true and shared_override.italic ~= true,
  '移除共享高亮覆写应恢复静态基线'
)
assert(
  vim.api.nvim_get_hl(0, { name = 'VVGitPanelBranch' }).link == 'Keyword',
  '移除 linked 高亮覆写应恢复默认 link'
)

Worktree.open_manager({ git_root = repo }, function() end)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
end, 10), '仅主 worktree 存在时也应可打开 manager')
local manager_buf = vim.api.nvim_get_current_buf()
assert(#vim.api.nvim_buf_get_lines(manager_buf, 0, -1, false) == 1, '应渲染单个主 worktree')
local mappings = vim.api.nvim_buf_get_keymap(manager_buf, 'n')
local actions = {}
for _, mapping in ipairs(mappings) do actions[mapping.desc or ''] = true end
assert(actions['vv-git-worktree: add'], 'manager 应暴露 add')
assert(actions['vv-git-worktree: remove'], 'manager 应暴露 remove')
assert(type(vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).footer) == 'table', 'footer 应使用高亮分段')
vim.api.nvim_feedkeys('r', 'x', false)
vim.wait(100, function() return false end, 10)
assert(vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()), 'manager 刷新时浮窗应保持有效')
assert(#vim.api.nvim_buf_get_lines(manager_buf, 0, -1, false) == 1, 'manager 刷新应渲染 worktree 列表')
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)

-- 关闭管理器后，尚未回答的创建提示不能继续访问 Git 或创建 worktree。
local original_select = vim.ui.select
local original_branches = Git.branches
local create_choice
local branch_queries = 0
vim.ui.select = function(_, opts, callback)
  if opts.prompt == 'Create worktree:' then create_choice = callback end
end
Git.branches = function(...)
  branch_queries = branch_queries + 1
  return original_branches(...)
end
Worktree.open_manager({ git_root = repo }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
end, 10), 'manager opens for the creation lifecycle check')
vim.api.nvim_feedkeys('a', 'x', false)
assert(vim.wait(1000, function() return create_choice ~= nil end, 10), 'create 提示应处于待确认状态')
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
create_choice('New branch')
assert(branch_queries == 0, '关闭 manager 应取消待执行的 create 流程')
vim.ui.select = original_select
Git.branches = original_branches

local added, add_err = await(function(cb)
  Git.worktree_add(repo, { path = linked, base = 'main', branch = 'feature' }, cb)
end)
assert(added, add_err or 'worktree add 失败')
assert(vim.fn.isdirectory(linked) == 1, 'worktree add 应创建 checkout 目录')

-- 从 linked worktree 创建时，默认布局仍锚定 main worktree，而不是嵌套到当前 checkout。
local original_input = vim.ui.input
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
end, 10), 'manager 应支持从 linked worktree 打开')
vim.api.nvim_feedkeys('a', 'x', false)
assert(vim.wait(5000, function() return suggested_path ~= nil end, 10), 'create 流程应到达路径提示')
assert(suggested_path == vim.uv.fs_realpath(repo) .. '/.worktrees/new-ui',
  'linked worktree 创建应使用主 worktree 布局根')
vim.ui.select, vim.ui.input = original_select, original_input
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)

-- Manager 打开后再被外部 lock：普通 remove 失败后必须重读状态，不能提供 force 绕过。
local original_confirm_open = Confirm.open
local original_notify = vim.notify
local lock_message
local lock_confirms = 0
Confirm.open = function(opts)
  lock_confirms = lock_confirms + 1
  return original_confirm_open(opts)
end
vim.notify = function(message, ...)
  lock_message = tostring(message)
  return original_notify(message, ...)
end
Worktree.open_manager({ git_root = repo }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
    and #vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false) == 2
end, 10), 'manager 应在锁竞争前渲染 linked worktree')
command({ 'git', '-C', repo, 'worktree', 'lock', linked })
vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
vim.api.nvim_feedkeys('d', 'x', false)
assert(vim.wait(5000, function()
  return lock_message and lock_message:find('Locked', 1, true)
end, 10), '锁定 worktree 的拒绝应完成反馈')
assert(vim.fn.isdirectory(linked) == 1, '渲染后锁定的 worktree 应被保留')
assert(lock_confirms == 0, '锁定删除竞争不应触发确认框')
command({ 'git', '-C', repo, 'worktree', 'unlock', linked })
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
Confirm.open = original_confirm_open
vim.notify = original_notify

-- 确认框打开后 worktree 变 dirty：不删除用户刚产生改动的 checkout。
local pending_confirm
local validation_message
Confirm.open = function(opts)
  pending_confirm = opts
  return { close = function() end }
end
vim.notify = function(message, ...)
  validation_message = tostring(message)
  return original_notify(message, ...)
end
Worktree.open_manager({ git_root = repo }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
    and #vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false) == 2
end, 10), 'manager 应在验证竞态前渲染 worktree')
vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
vim.api.nvim_feedkeys('d', 'x', false)
assert(vim.wait(1000, function() return pending_confirm ~= nil end, 10),
  '验证竞态应打开普通确认对话框')
local validation_dirty = linked .. '/validation-dirty.txt'
vim.fn.writefile({ 'dirty after confirmation' }, validation_dirty)
pending_confirm.on_confirm()
assert(vim.wait(5000, function() return validation_message ~= nil end, 10),
  '变更后的 worktree 应返回完成拒绝')
assert(vim.fn.isdirectory(linked) == 1, '确认后 dirty 修改应保留 worktree')
vim.fn.delete(validation_dirty)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
Confirm.open = original_confirm_open
vim.notify = original_notify

vim.fn.writefile({ 'dirty' }, linked .. '/dirty.txt')
local removed = await(function(cb) Git.worktree_remove(repo, linked, nil, cb) end)
assert(not removed, '普通删除应拒绝 dirty worktree')
assert(vim.fn.isdirectory(linked) == 1, '普通删除失败应保留目录')

local dirty, dirty_err = await(function(cb) Git.worktree_dirty(linked, cb) end)
assert(dirty == true, dirty_err or '在强制删除前应检测到 dirty worktree')
local confirm_titles = {}
Confirm.open = function(opts)
  confirm_titles[#confirm_titles + 1] = opts.title
  return original_confirm_open(opts)
end
Worktree.open_manager({ git_root = repo }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
    and #vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false) == 2
end, 10), 'manager 应渲染 dirty worktree')
vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
vim.api.nvim_feedkeys('d', 'x', false)
assert(vim.wait(1000, function()
  return confirm_titles[1] == 'Remove worktree?'
end, 10), '脏 worktree 删除应打开普通确认')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), 'x', false)
assert(vim.wait(5000, function()
  return confirm_titles[2] == 'Force remove worktree?'
end, 10), '普通删除失败后脏 worktree 删除应开启 force 确认')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), 'x', false)
assert(vim.wait(5000, function() return vim.fn.isdirectory(linked) == 0 end, 10), '确认后脏 worktree 删除应删除 checkout')
Confirm.open = original_confirm_open

-- clean worktree 走普通确认即可删除，不应误入 force 分支。
local clean = tmp .. '/repo-clean'
local clean_added, clean_add_err = await(function(cb)
  Git.worktree_add(repo, { path = clean, base = 'main', branch = 'clean' }, cb)
end)
assert(clean_added, clean_add_err or 'clean worktree fixture 创建失败')
confirm_titles = {}
Confirm.open = function(opts)
  confirm_titles[#confirm_titles + 1] = opts.title
  return original_confirm_open(opts)
end
Worktree.open_manager({ git_root = repo }, function() end, worktree_config)
assert(vim.wait(5000, function()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-git-worktree'
    and #vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false) == 2
end, 10), 'manager 应渲染 clean worktree')
vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
vim.api.nvim_feedkeys('d', 'x', false)
assert(vim.wait(1000, function() return confirm_titles[1] == 'Remove worktree?' end, 10),
  'clean 删除应打开普通确认')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), 'x', false)
assert(vim.wait(5000, function() return vim.fn.isdirectory(clean) == 0 end, 10),
  '确认 clean 删除应在无需 force 的情况下删除 checkout')
assert(confirm_titles[2] == nil, 'clean 删除不应打开 force 确认')
Confirm.open = original_confirm_open

vim.fn.delete(tmp, 'rf')
print('PASS: vv-git worktree 管理器')
