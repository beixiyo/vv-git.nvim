-- show_commit 必须把调用方的 gf 策略传到真实 revision session，避免关闭 vv-git 后误触发上层恢复

local test_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local plugin_root = vim.fn.fnamemodify(test_dir, ':h')
vim.opt.runtimepath:prepend(plugin_root)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(plugin_root, ':h') .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(plugin_root, ':h') .. '/vv-icons.nvim')

local Plugin = require('vv-git')
local State = require('vv-git.state')
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, 'p')
vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
vim.fn.writefile({ 'committed' }, tmpdir .. '/sample.txt')
vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })

Plugin.setup({ keymap_toggle_panel = false, auto_refresh = false, preview = false })

local goto_context
local close_count = 0
assert(Plugin.show_commit('HEAD', {
  root = tmpdir,
  on_close = function() close_count = close_count + 1 end,
  on_goto_file = function(context) goto_context = context end,
}), 'show_commit 应启动 revision 面板')

assert(vim.wait(3000, function()
  local state = State.current()
  return state and state.compare ~= nil and type(state._on_goto_file) == 'function'
end), 'show_commit 应将 gf 策略传入 revision state')

local state = assert(State.current())
local goto_map
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.panel.buf, 'n')) do
  if mapping.lhs == 'gf' then goto_map = mapping; break end
end
assert(goto_map and type(goto_map.callback) == 'function', 'revision panel 应安装 gf 回调')
goto_map.callback()

assert(vim.wait(1000, function() return goto_context ~= nil end), 'gf 应调用自定义跳转策略')
assert(goto_context.root == vim.uv.fs_realpath(tmpdir), 'gf context 应包含仓库 root')
assert(goto_context.path == 'sample.txt', 'gf context 应包含相对路径')
assert(Plugin.is_open(), '自定义 gf 策略应保留 vv-git tab')
assert(close_count == 0, '自定义 gf 策略不应触发 close 回调')

Plugin.close()
vim.fn.delete(tmpdir, 'rf')
print('PASS: vv-git revision gf 策略转发')
