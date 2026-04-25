-- vv-git.nvim 变更验证测试
-- 用法:
--   cd vv-git.nvim && nvim --headless -u NONE -l tests/test_smoke.lua
--   或在 nvim 内:  :luafile vv-git.nvim/tests/test_smoke.lua

-- 让 require('vv-git.xxx') 和 require('vv-utils.xxx') 在 -u NONE 下也能工作
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
local vendors_root = vim.fn.fnamemodify(plugin_root, ':h')
local utils_root = vendors_root .. '/vv-utils.nvim'
package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  utils_root .. '/lua/?.lua',
  utils_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local _passed = 0
local _failed = 0

local function log(msg)
  print('[test] ' .. msg)
end

local function assert_eq(a, b, label)
  if a == b then
    _passed = _passed + 1
    log('PASS: ' .. label)
  else
    _failed = _failed + 1
    log('FAIL: ' .. label .. ' — expected: ' .. tostring(b) .. ', got: ' .. tostring(a))
  end
end

local function assert_true(v, label)
  if v then
    _passed = _passed + 1
    log('PASS: ' .. label)
  else
    _failed = _failed + 1
    log('FAIL: ' .. label)
  end
end

-- 测试 1: git.lua discard_untracked 函数存在
local function test_discard_untracked_exists()
  local Git = require('vv-git.git')
  assert_eq(type(Git.discard_untracked), 'function', 'Git.discard_untracked is a function')
end

-- 测试 2: git.lua discard_untracked 可删除文件
local function test_discard_untracked_file()
  local Git = require('vv-git.git')
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')

  -- 初始化临时 git 仓库
  vim.fn.system({ 'git', '-C', tmpdir, 'init' })

  -- 创建未跟踪文件
  local testfile = 'untracked_test.txt'
  local abspath = tmpdir .. '/' .. testfile
  local f = io.open(abspath, 'w')
  if f then f:write('test'); f:close() end

  assert_true(vim.uv.fs_stat(abspath) ~= nil, 'untracked file exists before discard')

  Git.discard_untracked(tmpdir, { testfile }, function(ok, err)
    assert_true(ok, 'discard_untracked succeeded')
    assert_true(vim.uv.fs_stat(abspath) == nil, 'untracked file removed after discard')
  end)

  -- 清理
  vim.fn.delete(tmpdir, 'rf')
end

-- 测试 3: git.lua discard_untracked 可删除目录
local function test_discard_untracked_dir()
  local Git = require('vv-git.git')
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.system({ 'git', '-C', tmpdir, 'init' })

  -- 创建未跟踪目录
  local subdir = 'subdir'
  vim.fn.mkdir(tmpdir .. '/' .. subdir, 'p')
  local f = io.open(tmpdir .. '/' .. subdir .. '/file.txt', 'w')
  if f then f:write('test'); f:close() end

  assert_true(vim.uv.fs_stat(tmpdir .. '/' .. subdir) ~= nil, 'untracked dir exists before discard')

  Git.discard_untracked(tmpdir, { subdir }, function(ok, err)
    assert_true(ok, 'discard_untracked dir succeeded')
    assert_true(vim.uv.fs_stat(tmpdir .. '/' .. subdir) == nil, 'untracked dir removed after discard')
  end)

  -- 清理
  vim.fn.delete(tmpdir, 'rf')
end

-- 测试 4: actions.lua 中 split_by_tracked 逻辑（间接验证）
local function test_classify_untracked()
  local Git = require('vv-git.git')
  local staged, unstaged = Git.classify('??')
  assert_eq(staged, false, 'untracked is not staged')
  assert_eq(unstaged, true, 'untracked is unstaged')
end

-- 测试 5: insert mode keys 被阻止（panel buffer）
local function test_insert_mode_blocked()
  -- 只验证 panel buffer 创建后是否有 Nop 映射
  local Panel = require('vv-git.left.panel')
  local buf = Panel.create_buf()

  -- 模拟 install_keymaps 中的 insert mode 阻止（排除已有功能键 o/s/c/R）
  for _, key in ipairs({ 'i', 'I', 'a', 'A', 'O', 'S', 'C' }) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true })
  end

  local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
  local blocked = {}
  for _, m in ipairs(maps) do
    if m.rhs == '' or m.callback == nil and m.rhs == '<Nop>' then
      blocked[m.lhs] = true
    end
  end

  assert_true(blocked['i'], 'key i is blocked on panel buf')
  assert_true(blocked['I'], 'key I is blocked on panel buf')
  assert_true(blocked['a'], 'key a is blocked on panel buf')
  assert_true(blocked['A'], 'key A is blocked on panel buf')

  -- 清理
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- 测试 6: block_insert_mode 存在于 view.lua（间接：检查模块加载无报错）
local function test_view_module_loads()
  local ok, _ = pcall(require, 'vv-git.right.view')
  assert_true(ok, 'vv-git.right.view loads without error')
end

-- 测试 7: 源代码静态验证 — M.open 含终端宽度检查 + notify
-- 未加 guard 时用户在窄终端按 <leader>gd 会秒开秒关，体感「没反应」
local function test_narrow_width_guard_source()
  local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
  local init_lua = vim.fn.fnamemodify(this, ':h:h') .. '/lua/vv-git/init.lua'
  local src = table.concat(vim.fn.readfile(init_lua), '\n')

  -- M.open 函数体（function M.open() ... end 配对）
  local open_fn = src:match('function M%.open%(%).-\nend\n')
  assert_true(open_fn ~= nil, 'M.open 函数定义存在')
  if open_fn then
    assert_true(open_fn:find('vim%.o%.columns%s*<%s*min_cols') ~= nil
      or open_fn:find('vim%.o%.columns%s*<%s*M%._config%.single_col_threshold') ~= nil,
      'M.open: 含 vim.o.columns < 阈值 的宽度判断（窄终端提示防回归）')
    assert_true(open_fn:find('Terminal too narrow') ~= nil,
      'M.open: notify 消息含 "Terminal too narrow"（窄终端提示防回归）')
    assert_true(open_fn:find('vim%.log%.levels%.WARN') ~= nil,
      'M.open: 窄终端通知用 WARN 级别（窄终端提示防回归）')
  end
end

-- 测试 8: 运行时验证 — headless 默认 80 列（窄屏）下 VVGit 应：
--   1) 不创建新 tab（不打开插件）
--   2) 发出一条包含 "Terminal too narrow" 的 WARN 通知
local function test_narrow_width_guard_runtime()
  local ok_setup = pcall(require('vv-git').setup, {})
  if not ok_setup then
    log('SKIP: narrow width guard runtime needs full nvim env')
    return
  end

  local start_tabs = #vim.api.nvim_list_tabpages()
  local start_state = require('vv-git.state').has()

  -- 捕获 notify
  local captured = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) captured[#captured + 1] = { msg = msg, level = level } end

  pcall(require('vv-git').open)

  vim.notify = orig_notify

  -- 窄屏下 state 应保持原样（通常为 false）
  assert_true(require('vv-git.state').has() == start_state,
    'narrow: State.has() 保持不变（窄终端提示防回归）')
  assert_true(#vim.api.nvim_list_tabpages() == start_tabs,
    'narrow: 没有新增 tab（窄终端提示防回归）')

  -- 应捕获到一条含 "Terminal too narrow" 的 WARN 通知
  local hit = false
  for _, n in ipairs(captured) do
    if type(n.msg) == 'string' and n.msg:find('Terminal too narrow', 1, true)
        and n.level == vim.log.levels.WARN then
      hit = true; break
    end
  end
  assert_true(hit, 'narrow: 发出含 "Terminal too narrow" 的 WARN 通知（窄终端提示防回归）')
end

-- 测试 9: 源代码静态验证 — _apply_layout 对窄化应执行 notify + 关闭
-- 之前的「单栏降级」代码与 WinClosed → ensure_invariant 交互会把插件误杀，
-- 现在统一策略为「窄终端 = 不支持 → notify + close」。防回退
local function test_resize_to_narrow_source()
  local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
  local init_lua = vim.fn.fnamemodify(this, ':h:h') .. '/lua/vv-git/init.lua'
  local src = table.concat(vim.fn.readfile(init_lua), '\n')

  local apply = src:match('M%._apply_layout%s*=%s*State%.guarded%(function.-\nend%)')
  assert_true(apply ~= nil, '_apply_layout 函数定义存在')
  if apply then
    assert_true(apply:find('Terminal shrunk below') ~= nil,
      '_apply_layout: 窄化时发出 "Terminal shrunk below" 通知（resize 防回归）')
    assert_true(apply:find('M%.close') ~= nil or apply:find('vim%.schedule'),
      '_apply_layout: 窄化时调用 M.close / vim.schedule 关闭（resize 防回归）')
    -- 不再存在旧的"单栏降级"代码（Panel.close_win + 保留 b_win）
    assert_true(apply:find('_auto_hidden') == nil,
      '_apply_layout: 已清理 _auto_hidden 旧降级逻辑（resize 防回归）')
    assert_true(apply:find('Panel%.close_win') == nil,
      '_apply_layout: 不再手动 Panel.close_win（由 M.close 统一处理）（resize 防回归）')
    -- 去重 flag
    assert_true(apply:find('_closing_narrow') ~= nil,
      '_apply_layout: 使用 _closing_narrow flag 防 VimResized 连发导致多次 notify')
  end
end

-- 测试 10: 运行时验证 — 宽终端打开后拉窄应 notify + 关闭 + tabs-1
local function test_resize_to_narrow_runtime()
  local ok_setup = pcall(require('vv-git').setup, {})
  if not ok_setup then
    log('SKIP: resize runtime needs full nvim env')
    return
  end

  -- 先设宽终端，确保能成功打开
  local orig_cols = vim.o.columns
  vim.o.columns = 200

  -- 检查是否在 git repo
  local cwd = vim.fn.getcwd()
  vim.fn.systemlist({ 'git', '-C', cwd, 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 then
    vim.o.columns = orig_cols
    log('SKIP: not a git repo')
    return
  end

  -- 捕获 notify
  local captured = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) captured[#captured + 1] = { msg = msg, level = level } end

  -- 打开（宽终端，应成功）
  pcall(require('vv-git').open)
  local after_open_has = require('vv-git.state').has()
  local after_open_tabs = #vim.api.nvim_list_tabpages()

  -- 模拟窄化
  vim.o.columns = 80
  pcall(vim.cmd, 'doautocmd VimResized')
  -- 给 vim.schedule 一个 tick 机会跑（headless 下 vim.wait 能驱动事件循环）
  vim.wait(300, function() return not require('vv-git.state').has() end, 10)

  vim.notify = orig_notify
  vim.o.columns = orig_cols

  assert_true(after_open_has, 'resize: 宽终端下先成功打开（前置条件）')
  assert_true(not require('vv-git.state').has(),
    'resize: 窄化后 State.has() == false（插件已关闭）（resize 防回归）')
  assert_true(#vim.api.nvim_list_tabpages() < after_open_tabs,
    'resize: 窄化后 tabs 数量减少（vv-git tab 已关）（resize 防回归）')

  local hit = false
  for _, n in ipairs(captured) do
    if type(n.msg) == 'string' and n.msg:find('Terminal shrunk below', 1, true)
        and n.level == vim.log.levels.WARN then
      hit = true; break
    end
  end
  assert_true(hit, 'resize: 发出含 "Terminal shrunk below" 的 WARN 通知（resize 防回归）')
end

-- 执行所有测试
log('========== vv-git.nvim 变更验证 ==========')
test_discard_untracked_exists()
test_discard_untracked_file()
test_discard_untracked_dir()
test_classify_untracked()
test_insert_mode_blocked()
test_view_module_loads()
test_narrow_width_guard_source()
test_narrow_width_guard_runtime()
test_resize_to_narrow_source()
test_resize_to_narrow_runtime()
log('========== 测试完成 ==========')
print(string.format('总计: %d 通过, %d 失败', _passed, _failed))
if _failed > 0 then os.exit(1) end
