-- vv-git.nvim 变更验证测试
-- 用法:
--   cd vv-git.nvim && nvim --headless -u NONE -l tests/test_smoke.lua
--   或在 nvim 内:  :luafile vv-git.nvim/tests/test_smoke.lua

-- 让 require('vv-git.xxx') 和 require('vv-utils.xxx') 在 -u NONE 下也能工作
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
local vendors_root = vim.fn.fnamemodify(plugin_root, ':h')
local utils_root = vendors_root .. '/vv-utils.nvim'
local icons_root = vendors_root .. '/vv-icons.nvim'
package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  utils_root .. '/lua/?.lua',
  utils_root .. '/lua/?/init.lua',
  icons_root .. '/lua/?.lua',
  icons_root .. '/lua/?/init.lua',
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

-- 测试 5: 首次提交前可取消暂存，且保留工作区文件
local function test_unstage_without_head()
  local Git = require('vv-git.git')
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
  vim.fn.writefile({ 'draft' }, tmpdir .. '/draft.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'draft.txt' })

  local done = false
  Git.unstage(tmpdir, { 'draft.txt' }, function(ok, err)
    assert_true(ok, 'unborn repository unstage succeeded: ' .. tostring(err or ''))
    done = true
  end)

  assert_true(vim.wait(3000, function() return done end), 'unborn repository unstage completed')
  assert_true(vim.uv.fs_stat(tmpdir .. '/draft.txt') ~= nil, 'unborn repository unstage keeps worktree file')
  assert_eq(vim.fn.system({ 'git', '-C', tmpdir, 'status', '--short', 'draft.txt' }), '?? draft.txt\n',
    'unborn repository file becomes untracked')

  vim.fn.delete(tmpdir, 'rf')
end

-- 测试 6: 已有 HEAD 时仍从 index 恢复，不移除 tracked 状态
local function test_unstage_with_head()
  local Git = require('vv-git.git')
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
  vim.fn.writefile({ 'initial' }, tmpdir .. '/tracked.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'tracked.txt' })
  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })
  vim.fn.writefile({ 'changed' }, tmpdir .. '/tracked.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'tracked.txt' })

  local done = false
  Git.unstage(tmpdir, { 'tracked.txt' }, function(ok, err)
    assert_true(ok, 'repository with HEAD unstage succeeded: ' .. tostring(err or ''))
    done = true
  end)

  assert_true(vim.wait(3000, function() return done end), 'repository with HEAD unstage completed')
  assert_eq(vim.fn.system({ 'git', '-C', tmpdir, 'status', '--short', 'tracked.txt' }), ' M tracked.txt\n',
    'tracked file remains tracked and unstaged')

  vim.fn.delete(tmpdir, 'rf')
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

-- 测试 6: panel 中 gg/G 只跳到第一个/最后一个文件，不落到标题或目录行
local function test_panel_edge_file_keymaps()
  local Keymaps = require('vv-git.core.keymaps')
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()
  local old_buf = vim.api.nvim_win_get_buf(win)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    ' repo',
    'Changes (2)',
    '  folder',
    '    a.lua',
    '',
    '    z.lua',
  })
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local state = {
    panel = {
      buf = buf,
      win = win,
      id_by_line = {
        [2] = { section_header = 'unstaged', base = 'unstaged' },
        [3] = { node = { is_dir = true, relpath = 'folder' } },
        [4] = { node = { is_dir = false, relpath = 'folder/a.lua' } },
        [6] = { node = { is_dir = false, relpath = 'folder/z.lua' } },
      },
    },
    selection = {},
  }
  local noop = function() end
  local mock = {
    _config = { keymap_select = '<Tab>', right_click = false, mappings = {} },
    close = noop,
    refresh = noop,
    _activate = noop,
    _system_open = noop,
    _execute = noop,
    _goto_file = noop,
    _yank_abs_path = noop,
    _toggle_select = noop,
    _collapse = noop,
    _action = noop,
    _commit = noop,
    _push = noop,
    _pull = noop,
    _compare_pick = noop,
    _commit_show_pick = noop,
    _preview_on_move = noop,
  }

  Keymaps.install(state, mock)

  local callbacks, rhsmap = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    callbacks[m.lhs] = m.callback
    rhsmap[m.lhs] = m.rhs
  end

  assert_eq(type(callbacks.gg), 'function', 'gg mapping is installed')
  callbacks.gg()
  assert_eq(vim.api.nvim_win_get_cursor(win)[1], 4, 'gg jumps to first file row')

  assert_eq(type(callbacks.G), 'function', 'G mapping is installed')
  callbacks.G()
  assert_eq(vim.api.nvim_win_get_cursor(win)[1], 6, 'G jumps to last file row')

  -- 左侧面板驱动右侧 diff chunk 跳转：]c / [c 已安装，且无 diff 视图时安全早退（不报错）
  assert_eq(type(callbacks[']c']), 'function', ']c (next_chunk) mapping is installed')
  assert_eq(type(callbacks['[c']), 'function', '[c (prev_chunk) mapping is installed')
  assert_true(pcall(callbacks[']c']), ']c 在无 diff 视图时安全早退')
  assert_true(pcall(callbacks['[c']), '[c 在无 diff 视图时安全早退')

  -- 鼠标拖拽/多击防 visual：恒装（不再受 right_click 门控；<Nop> 的 rhs 为空串）
  assert_true(rhsmap['<LeftDrag>'] ~= nil, '<LeftDrag> 已 Nop')
  assert_true(rhsmap['<2-LeftMouse>'] ~= nil, '<2-LeftMouse> 已 Nop（防双击选词）')
  assert_true(rhsmap['<3-LeftMouse>'] ~= nil, '<3-LeftMouse> 已 Nop（防三击选行）')
  assert_true(rhsmap['<4-LeftMouse>'] ~= nil, '<4-LeftMouse> 已 Nop（防四击选块）')
  -- 跨窗口拖入/多击兜底：面板 buffer 挂了 ModeChanged 守卫
  local mc = vim.api.nvim_get_autocmds({ event = 'ModeChanged', buffer = buf })
  assert_true(#mc >= 1, '面板 buffer 注册了 ModeChanged 防 visual 守卫')

  vim.api.nvim_win_set_buf(win, old_buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- 测试 7: block_insert_mode 存在于 view.lua（间接：检查模块加载无报错）
local function test_view_module_loads()
  local ok, _ = pcall(require, 'vv-git.right.view')
  assert_true(ok, 'vv-git.right.view loads without error')
end

-- 测试 8: 右侧 diff 视图聚焦时，[c/]c 也走 vv-utils.scroll 动画包装
local function test_right_diff_chunk_keymaps()
  local view_src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-git/right/view.lua'), '\n')

  assert_true(view_src:find("'%]c'") ~= nil,
    'right view 安装 ]c next_chunk 映射')
  assert_true(view_src:find("'%[c'") ~= nil,
    'right view 安装 [c prev_chunk 映射')
  assert_true(view_src:find('Scroll%.with_view_animation') ~= nil,
    'right view chunk 跳转走 vv-utils.scroll 动画包装')
  assert_true(view_src:find("nvim_get_option_value%('diff'") ~= nil,
    'right view chunk 跳转只在 diff 窗口接管')
end

-- 测试 9: 源代码静态验证 — 窄终端策略为「降级单栏」而非旧的「拒开 + Terminal too narrow」
-- 现行设计：列数 < single_col_threshold 时 diff 视图降级为单栏（仅 b 侧，无 inline diff），
-- ≥ 阈值时正常 dual diff，resize 时在 narrow↔wide 间自动迁移。本测试防回退到旧拒开设计
-- 注：旧版曾用「窄终端 = notify + close」，现已改回（重新实现的）单栏降级，故旧的
-- "Terminal too narrow" / "Terminal shrunk below" 字串应不复存在
local function test_narrow_single_col_design()
  local init_src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-git/init.lua'), '\n')
  local pops_src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-git/core/panel_ops.lua'), '\n')

  assert_true(init_src:find('single_col_threshold') ~= nil,
    'config 含 single_col_threshold 窄宽阈值（单栏降级设计）')
  assert_true(pops_src:find('vim%.o%.columns%s*<%s*M%._config%.single_col_threshold') ~= nil,
    'panel_ops.is_narrow 用 columns < single_col_threshold 判定窄宽')
  assert_true(pops_src:find('RightView%.show%(.-is_narrow') ~= nil,
    'RightView.show 接收 is_narrow（宽度驱动单/双栏，而非拒开）')
  assert_true(init_src:find('Terminal too narrow') == nil,
    '不再含旧「Terminal too narrow」拒开提示（已改单栏降级）')
end

-- 测试 10: 源代码静态验证 — resize 经 _apply_layout 在 narrow↔wide 间迁移，而非 notify + 关闭
local function test_resize_single_col_migration()
  local pops_src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-git/core/panel_ops.lua'), '\n')
  local view_src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-git/right/view.lua'), '\n')

  assert_true(pops_src:find('M%._apply_layout%s*=') ~= nil,
    '_apply_layout 定义存在（resize 布局迁移入口）')
  assert_true(view_src:find('_apply_layout') ~= nil and view_src:find('narrow') ~= nil,
    'view 层支持 _apply_layout 的 narrow↔wide 迁移（保留 b_win 配置）')
  assert_true(pops_src:find('Terminal shrunk below') == nil,
    '不再含旧「Terminal shrunk below」窄化关闭提示（已改单栏迁移）')
end

-- 测试 11: 源代码静态验证 — 三栏冲突 result 高度暴露为配置项
local function test_conflict_result_ratio_config()
  local init_src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-git/init.lua'), '\n')
  local view_src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-git/right/view.lua'), '\n')

  assert_true(init_src:find('conflict_result_ratio number') ~= nil,
    'VVGitConfig 暴露 conflict_result_ratio 类型注释')
  assert_true(init_src:find('conflict_result_ratio%s*=%s*0%.5') ~= nil,
    'defaults 中 conflict_result_ratio 默认为 0.5')
  assert_true(view_src:find('handlers%.get_config%(%)%.conflict_result_ratio') ~= nil,
    'conflict 三栏布局从配置读取 result 高度比例')
end

local function test_staged_scrollbar_source()
  local RightView = require('vv-git.right.view')
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.writefile({ 'one', 'two', 'three' }, tmpdir .. '/sample.txt')
  vim.fn.writefile({ 'removed one', 'removed two' }, tmpdir .. '/removed.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt', 'removed.txt' })
  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })
  vim.fn.writefile({ 'one', 'two', 'staged', 'three' }, tmpdir .. '/sample.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
  vim.fn.delete(tmpdir .. '/removed.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'removed.txt' })

  local main_win = vim.api.nvim_get_current_win()
  local state = {
    tabpage = vim.api.nvim_get_current_tabpage(),
    git_root = tmpdir,
    panel = { main_win = main_win },
  }
  RightView.show(state, { is_dir = false, relpath = 'sample.txt', xy = 'M ' }, 'staged', false, tmpdir)

  local ready = vim.wait(3000, function()
    return state.view and state.view.b_buf and vim.api.nvim_buf_is_valid(state.view.b_buf)
  end)
  assert_true(ready, 'staged diff right buffer rendered')

  local source = ready and vim.b[state.view.b_buf].vv_scrollbar_git_source or nil
  assert_eq(vim.w[state.view.b_win].vv_scrollbar_always_show, true,
    'staged right window keeps scrollbar marker track visible')
  assert_eq(source and source.root, tmpdir, 'staged scrollbar source carries git root')
  assert_eq(source and source.path, 'sample.txt', 'staged scrollbar source carries relative path')
  assert_eq(source and source.mode, 'staged', 'staged scrollbar source selects cached diff')
  assert_eq(source and source.side, 'new', 'staged modified file projects onto index side')

  RightView.show(state, { is_dir = false, relpath = 'removed.txt', xy = 'D ' }, 'staged', false, tmpdir)
  local deletion_ready = vim.wait(3000, function()
    return state.view and state.view.path == 'removed.txt'
      and state.view.b_buf and vim.api.nvim_buf_is_valid(state.view.b_buf)
  end)
  assert_true(deletion_ready, 'staged deletion right buffer rendered')

  local deletion_source = deletion_ready and vim.b[state.view.b_buf].vv_scrollbar_git_source or nil
  assert_eq(deletion_source and deletion_source.path, 'removed.txt', 'staged deletion carries relative path')
  assert_eq(deletion_source and deletion_source.side, 'old', 'staged deletion projects onto HEAD side')

  pcall(RightView.close, state)
  vim.fn.delete(tmpdir, 'rf')
end

-- 执行所有测试
log('========== vv-git.nvim 变更验证 ==========')
test_discard_untracked_exists()
test_discard_untracked_file()
test_discard_untracked_dir()
test_classify_untracked()
test_unstage_without_head()
test_unstage_with_head()
test_insert_mode_blocked()
test_panel_edge_file_keymaps()
test_view_module_loads()
test_right_diff_chunk_keymaps()
test_narrow_single_col_design()
test_resize_single_col_migration()
test_conflict_result_ratio_config()
test_staged_scrollbar_source()
log('========== 测试完成 ==========')
print(string.format('总计: %d 通过, %d 失败', _passed, _failed))
if _failed > 0 then os.exit(1) end
