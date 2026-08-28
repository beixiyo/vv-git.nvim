-- 非 Git cwd 的初始化闭环：打开空状态、展示快捷键、执行真实 git init、原地切回仓库视图

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Plugin = require('vv-git')
local State = require('vv-git.state')

local function mapping_callback(buf, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if mapping.lhs == lhs then return mapping.callback end
  end
end

Plugin.setup({
  auto_refresh = false,
  preview = false,
  keymap_toggle_panel = false,
  subrepo = { depth = 0 },
})

local init_dir = vim.fn.tempname()
vim.fn.mkdir(init_dir, 'p')
local original_cwd = vim.fn.getcwd()
vim.cmd('cd ' .. vim.fn.fnameescape(init_dir))

local ready_context
assert(Plugin.open({
  on_ready = function(context) ready_context = context end,
}), '非 Git cwd 应打开初始化空状态')
assert(vim.wait(1000, function() return ready_context ~= nil end), '初始化空状态未触发 ready')

local state = State.get()
local expected_root = vim.uv.fs_realpath(init_dir)
assert(state.git_root == nil, 'git init 前不应伪造 git_root')
assert(state.init_root == expected_root, '初始化目标应绑定当前 cwd')
assert(ready_context.root == expected_root, '初始化空状态 context 应暴露目标 cwd')

local lines = vim.api.nvim_buf_get_lines(state.panel.buf, 0, -1, false)
assert(vim.tbl_contains(lines, '  Not a Git repository'), '空状态应说明当前目录不是 Git 仓库')
assert(vim.tbl_contains(lines, '  i  Initialize Git repository'), '空状态应展示 git init 快捷键')

local init_mapping = mapping_callback(state.panel.buf, 'i')
assert(type(init_mapping) == 'function', '空状态应安装 i 初始化映射')
init_mapping()

assert(vim.wait(3000, function()
  return state.git_root == expected_root and state.init_root == nil and state.tree ~= nil
end), 'git init 成功后应在当前面板原地进入仓库状态')
assert(vim.fn.isdirectory(init_dir .. '/.git') == 1, '初始化快捷键应创建真实 .git 目录')

lines = vim.api.nvim_buf_get_lines(state.panel.buf, 0, -1, false)
assert(not vim.tbl_contains(lines, '  i  Initialize Git repository'), '初始化成功后应移除空状态快捷键提示')

Plugin.close()
assert(vim.wait(1000, function() return not Plugin.is_open() end), '初始化测试面板未关闭')
vim.wait(50, function() return false end)

-- 真实回归：HOME-as-repo 一类场景中，工作目录被祖先仓库忽略。不能静默打开父仓库，
-- 应保留当前目录与祖先 root 两个事实，让用户选择打开父仓库或在这里初始化嵌套仓库
local parent_dir = vim.fn.tempname()
local child_dir = parent_dir .. '/agents'
vim.fn.mkdir(child_dir, 'p')
assert(vim.system({ 'git', '-C', parent_dir, 'init' }, { text = true }):wait().code == 0, '父仓库 fixture 初始化失败')
vim.fn.writefile({ '*' }, parent_dir .. '/.gitignore')
vim.cmd('cd ' .. vim.fn.fnameescape(child_dir))

ready_context = nil
assert(Plugin.open({ on_ready = function(context) ready_context = context end }), '祖先仓库场景应打开决策页')
assert(vim.wait(1000, function() return ready_context ~= nil end), '祖先仓库决策页未触发 ready')

state = State.get()
local expected_parent = vim.uv.fs_realpath(parent_dir)
local expected_child = vim.uv.fs_realpath(child_dir)
assert(state.git_root == nil, 'prompt 模式不应静默采用祖先仓库')
assert(state.init_root == expected_child, '决策页应保留当前工作目录作为初始化目标')
assert(state.parent_root == expected_parent, '决策页应单独保留祖先仓库根')
assert(state.parent_ignored == true, '被父仓库忽略的目录应作为默认初始化候选')
assert(ready_context.root == expected_child, '决策页 context.root 应保持用户打开的工作目录')
assert(ready_context.parent_root == expected_parent, '决策页 context 应单独暴露祖先仓库候选')

lines = vim.api.nvim_buf_get_lines(state.panel.buf, 0, -1, false)
assert(vim.tbl_contains(lines, '  Parent Git repository found'), '决策页应说明发现祖先仓库')
assert(vim.tbl_contains(lines, '  ' .. expected_parent), '决策页应显示祖先仓库绝对路径')
assert(vim.tbl_contains(lines, '  p  Open parent repository'), '决策页应提供打开祖先仓库快捷键')
assert(vim.tbl_contains(lines, '  i  Initialize Git repository here'), '决策页应提供当前目录初始化快捷键')

local cursor_line = vim.api.nvim_win_get_cursor(state.panel.win)[1]
assert(
  state.panel.id_by_line[cursor_line]
      and state.panel.id_by_line[cursor_line].repository_action == 'init',
  '被父仓库忽略时默认光标应落在当前目录初始化动作'
)

local parent_mapping = mapping_callback(state.panel.buf, 'p')
assert(type(parent_mapping) == 'function', '决策页应安装 p 打开祖先仓库映射')
parent_mapping()
assert(vim.wait(3000, function()
  return state.git_root == expected_parent and state.init_root == nil and state.tree ~= nil
end), 'p 应在当前面板原地打开祖先仓库')
assert(vim.fn.isdirectory(child_dir .. '/.git') == 0, '打开祖先仓库不应初始化当前目录')

Plugin.close()
assert(vim.wait(1000, function() return not Plugin.is_open() end), '祖先仓库面板未关闭')
vim.wait(50, function() return false end)

ready_context = nil
assert(Plugin.open({ on_ready = function(context) ready_context = context end }), '应能重新打开已确认的祖先仓库')
assert(vim.wait(3000, function() return ready_context ~= nil end), '重开已确认的祖先仓库未触发 ready')
state = State.get()
assert(state.git_root == expected_parent, '同一 Neovim 会话应记住该目录选择的祖先仓库')
assert(state.init_root == nil and state.parent_root == nil, '已确认的目录不应再次进入决策页')

Plugin.close()
assert(vim.wait(1000, function() return not Plugin.is_open() end), '记忆祖先仓库面板未关闭')
vim.wait(50, function() return false end)

-- 另一个目录仍是独立决策，不把一个 target_dir 的选择泄漏到同一父仓库下的其它目录
local init_child_dir = parent_dir .. '/agents-init'
vim.fn.mkdir(init_child_dir, 'p')
vim.cmd('cd ' .. vim.fn.fnameescape(init_child_dir))
ready_context = nil
assert(Plugin.open({ on_ready = function(context) ready_context = context end }), '新目录应打开自己的祖先仓库决策页')
assert(vim.wait(1000, function() return ready_context ~= nil end), '新目录祖先仓库决策页未触发 ready')
state = State.get()
local expected_init_child = vim.uv.fs_realpath(init_child_dir)
assert(state.init_root == expected_init_child and state.parent_root == expected_parent, '父仓库选择记忆必须按 target_dir 隔离')
init_mapping = mapping_callback(state.panel.buf, 'i')
assert(type(init_mapping) == 'function', '祖先仓库决策页应安装 i 初始化映射')
local activate_mapping = mapping_callback(state.panel.buf, '<CR>')
assert(type(activate_mapping) == 'function', '祖先仓库决策页应允许用 <CR> 执行当前选项')
activate_mapping()
assert(vim.wait(3000, function()
  return state.git_root == expected_init_child and state.init_root == nil and state.tree ~= nil
end), 'i 应在当前目录创建嵌套仓库并原地打开')
assert(vim.fn.isdirectory(init_child_dir .. '/.git') == 1, 'i 应在选择的当前目录创建真实 .git')

Plugin.close()
assert(vim.wait(1000, function() return not Plugin.is_open() end), '嵌套仓库面板未关闭')
vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(init_dir, 'rf')
vim.fn.delete(parent_dir, 'rf')
print('PASS: vv-git 非仓库 cwd 初始化闭环')
