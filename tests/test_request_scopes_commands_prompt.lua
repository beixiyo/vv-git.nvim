-- vv-git command 与 prompt request-scope 回归

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  .. '/helpers/request_scope.lua')
local assert_eq = H.assert_eq
local noop = H.noop
local Commands = require('vv-git.core.commands')
local Git = require('vv-git.git')
local Keymaps = require('vv-git.core.keymaps')
local Prompt = require('vv-git.left.prompt')
local State = require('vv-git.state')
local state = State.create()

-- 捕获的 panel root 不再受当前 owner 持有时，commit 和 publish 链必须停止
local original_cursor = Keymaps.id_under_cursor
local original_has_staged = Git.has_staged
local original_repo_info = Git.repo_info
local original_add_remote = Git.add_remote
local original_publish = Git.publish
local original_prompt_open = Prompt.open
local original_prompt_close = Prompt.close
local original_input = vim.ui.input

Keymaps.id_under_cursor = function() return nil end
local staged_callback
local prompt_opens = 0
Git.has_staged = function(_, callback) staged_callback = callback end
Prompt.open = function() prompt_opens = prompt_opens + 1 end
Prompt.close = noop

local command_controller = {
  refresh = noop,
  _invoke_callback = noop,
  _context = function() return {} end,
}
local commands = Commands.new({ controller = command_controller, config = function() return { binary = {} } end })
state.git_root = '/repo-a'
commands._commit()
state.git_root = '/repo-b'
staged_callback(true)
assert_eq(prompt_opens, 0, 'late staged check cannot open a commit prompt for the old root')
commands._cancel_command_requests()

local repo_info_callback
local input_callback
local add_remote_callback
local publishes = 0
local repo_info_cancels = 0
local add_remote_cancels = 0
local publish_cancels = 0
Git.repo_info = function(_, callback)
  repo_info_callback = callback
  return function() repo_info_cancels = repo_info_cancels + 1 end
end
vim.ui.input = function(_, callback) input_callback = callback end
Git.add_remote = function(_, _, _, callback)
  add_remote_callback = callback
  return function() add_remote_cancels = add_remote_cancels + 1 end
end
Git.publish = function()
  publishes = publishes + 1
  return function() publish_cancels = publish_cancels + 1 end
end

state.git_root = '/repo-a'
commands._publish()
commands._cancel_command_requests()
assert_eq(repo_info_cancels, 1, 'publish lifecycle cancellation reaches repo_info producers')

state.git_root = '/repo-a'
commands._publish()
repo_info_callback({
  branch_name = 'main',
  detached = false,
  unborn = false,
  head = 'abc',
  upstream = nil,
  remotes = {},
})
input_callback('git@example/repo.git')
state.git_root = '/repo-b'
add_remote_callback(true)
assert_eq(publishes, 0, 'root change between add-remote and publish stops the old chain')
commands._cancel_command_requests()
assert_eq(add_remote_cancels, 1, 'publish lifecycle cancellation reaches add-remote producer')

state.git_root = '/repo-a'
commands._publish()
repo_info_callback({
  branch_name = 'main',
  detached = false,
  unborn = false,
  head = 'abc',
  upstream = nil,
  remotes = { 'origin' },
})
assert_eq(publishes, 1, 'publish producer starts after repository inspection')
commands._cancel_command_requests()
assert_eq(publish_cancels, 1, 'publish lifecycle cancellation reaches active push producer')

Keymaps.id_under_cursor = original_cursor
Git.has_staged = original_has_staged
Git.repo_info = original_repo_info
Git.add_remote = original_add_remote
Git.publish = original_publish
Prompt.open = original_prompt_open
Prompt.close = original_prompt_close
vim.ui.input = original_input

-- Prompt 持有 stage-all → commit 边界，失效后不得再启动 commit
local original_stage_all = Git.stage_all
local original_commit = Git.commit
local stage_all_callback
local commit_callback
local stage_all_opts
local commit_opts
local commit_calls = 0
local prompt_current = true
Git.stage_all = function(_, callback, opts)
  stage_all_callback = callback
  stage_all_opts = opts
end
Git.commit = function(_, _, callback, opts)
  commit_calls = commit_calls + 1
  commit_callback = callback
  commit_opts = opts
end

Prompt.open({
  git_root = '/repo-a',
  has_staged = false,
  is_current = function() return prompt_current end,
})
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'test commit' })
local submit_mapping = vim.fn.maparg('<C-s>', 'i', false, true)
assert(type(submit_mapping.callback) == 'function', 'production prompt installs the submit callback')
submit_mapping.callback()
assert(type(stage_all_callback) == 'function', 'commit-all starts stage_all while the owner is current')
assert(type(stage_all_opts) == 'table' and type(stage_all_opts.is_current) == 'function',
  'prompt passes its current-owner guard to stage_all')
prompt_current = false
stage_all_callback(true)
assert_eq(commit_calls, 0, 'invalidated prompt cannot continue from stage_all into commit')
Prompt.close()

prompt_current = true
Prompt.open({
  git_root = '/repo-a',
  has_staged = false,
  is_current = function() return prompt_current end,
})
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'test commit' })
vim.fn.maparg('<C-s>', 'i', false, true).callback()
stage_all_callback(true)
assert_eq(commit_calls, 1, 'current prompt continues from stage_all into commit')
assert(type(commit_opts) == 'table' and commit_opts.is_current == stage_all_opts.is_current,
  'prompt passes the same current-owner guard to commit')
prompt_current = false
commit_callback(true)
assert_eq(commit_calls, 1, 'invalidated prompt does not start a second commit')
Prompt.close()

local successes = 0
prompt_current = true
Prompt.open({
  git_root = '/repo-a',
  has_staged = true,
  is_current = function() return prompt_current end,
  on_success = function() successes = successes + 1 end,
})
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'test commit' })
vim.fn.maparg('<C-s>', 'i', false, true).callback()
assert_eq(commit_calls, 2, 'current prompt starts commit')
prompt_current = false
commit_callback(true)
assert_eq(successes, 0, 'invalidated commit callback cannot publish success side effects')
Prompt.close()

Git.stage_all = original_stage_all
Git.commit = original_commit

-- Prompt 挂载可同步启动 B；A 的晚到 disposer 必须仍只处理自身 owner
vim.cmd('stopinsert')
vim.cmd('only')
local prompt_a_current = true
local dispose_prompt_b
local prompt_reentry_group = vim.api.nvim_create_augroup('VVGitPromptReentryTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = prompt_reentry_group,
  once = true,
  callback = function()
    prompt_a_current = false
    dispose_prompt_b = Prompt.open({
      git_root = '/repo-b',
      has_staged = true,
      is_current = function() return true end,
    })
  end,
})
local dispose_prompt_a = Prompt.open({
  git_root = '/repo-a',
  has_staged = true,
  is_current = function() return prompt_a_current end,
})
local prompt_b_win = vim.api.nvim_get_current_win()
local prompt_b_buf = vim.api.nvim_get_current_buf()
dispose_prompt_a()
assert(vim.api.nvim_win_is_valid(prompt_b_win) and vim.api.nvim_buf_is_valid(prompt_b_buf),
  'stale prompt disposer closed the reentrant replacement prompt')
dispose_prompt_b()

-- root 或生命周期失效后，push/pull 回调不得发布结果
local original_push = Git.push
local original_notify = vim.notify
local push_callback
local push_cancels = 0
local net_notifications = 0
local net_refreshes = 0
Git.push = function(_, callback)
  push_callback = callback
  return function() push_cancels = push_cancels + 1 end
end
vim.notify = function() net_notifications = net_notifications + 1 end
local net_commands = Commands.new({
  controller = {
    refresh = function() net_refreshes = net_refreshes + 1 end,
    _invoke_callback = noop,
    _context = function() return {} end,
  },
  config = function() return { binary = {} } end,
})
state.git_root = '/repo-a'
net_commands._push()
assert_eq(net_notifications, 1, 'push start notification is emitted while current')
state.git_root = '/repo-b'
push_callback(true, 'done')
assert_eq(net_notifications, 1, 'stale push callback emits no completion notification')
assert_eq(net_refreshes, 0, 'stale push callback cannot refresh the new root')

state.git_root = '/repo-a'
net_commands._push()
net_commands._invalidate_command_requests()
assert_eq(push_cancels, 0, 'closing UI does not terminate the active push producer')
push_callback(true, 'done')
assert_eq(net_notifications, 2, 'invalidated push callback emits no completion notification')
assert_eq(net_refreshes, 0, 'invalidated push callback cannot refresh')

net_commands._push()
net_commands._cancel_command_requests()
assert_eq(push_cancels, 1, 'push lifecycle cancellation reaches its active producer')
push_callback(true, 'done')
assert_eq(net_notifications, 3, 'cancelled push callback emits no completion notification')
assert_eq(net_refreshes, 0, 'cancelled push callback cannot refresh')
Git.push = original_push
vim.notify = original_notify

State.clear()
print('vv-git request scopes commands and prompt: PASS')
