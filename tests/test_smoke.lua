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

-- 测试 1: git.lua discard_untracked 可删除文件
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

  assert_true(vim.uv.fs_stat(abspath) ~= nil, 'discard 前未跟踪文件存在')

  Git.discard_untracked(tmpdir, { testfile }, function(ok, err)
    assert_true(ok, 'discard_untracked 成功')
    assert_true(vim.uv.fs_stat(abspath) == nil, 'discard 后未跟踪文件已移除')
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

  assert_true(vim.uv.fs_stat(tmpdir .. '/' .. subdir) ~= nil, 'discard 前未跟踪目录存在')

  Git.discard_untracked(tmpdir, { subdir }, function(ok, err)
    assert_true(ok, 'discard_untracked 目录成功')
    assert_true(vim.uv.fs_stat(tmpdir .. '/' .. subdir) == nil, 'discard 后未跟踪目录已移除')
  end)

  -- 清理
  vim.fn.delete(tmpdir, 'rf')
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
    assert_true(ok, '无 HEAD 仓库取消暂存成功: ' .. tostring(err or ''))
    done = true
  end)

  assert_true(vim.wait(3000, function() return done end), '无 HEAD 仓库取消暂存完成')
  assert_true(vim.uv.fs_stat(tmpdir .. '/draft.txt') ~= nil, '无 HEAD 仓库取消暂存保留工作区文件')
  assert_eq(vim.fn.system({ 'git', '-C', tmpdir, 'status', '--short', 'draft.txt' }), '?? draft.txt\n',
    '无 HEAD 仓库下状态应显示未跟踪')

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
    assert_true(ok, '有 HEAD 仓库取消暂存成功: ' .. tostring(err or ''))
    done = true
  end)

  assert_true(vim.wait(3000, function() return done end), '有 HEAD 仓库取消暂存完成')
  assert_eq(vim.fn.system({ 'git', '-C', tmpdir, 'status', '--short', 'tracked.txt' }), ' M tracked.txt\n',
    '跟踪文件仍为已跟踪且未暂存状态')

  vim.fn.delete(tmpdir, 'rf')
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
  local toggle_diff_calls = 0
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
    _toggle_diff_folds = function() toggle_diff_calls = toggle_diff_calls + 1 end,
    _action = noop,
    _commit = noop,
    _push = noop,
    _pull = noop,
    _publish = noop,
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

  assert_eq(type(callbacks.gg), 'function', '已安装 gg 映射')
  callbacks.gg()
  assert_eq(vim.api.nvim_win_get_cursor(win)[1], 4, 'gg 跳转到首个文件行')

  assert_eq(type(callbacks.G), 'function', '已安装 G 映射')
  callbacks.G()
  assert_eq(vim.api.nvim_win_get_cursor(win)[1], 6, 'G 跳转到最后文件行')
  assert_eq(type(callbacks.u), 'function', '已安装 u（publish）映射')
  assert_eq(type(callbacks.zR), 'function', '已安装 zR（切换右侧 diff 折叠）映射')
  assert_true(rhsmap.i ~= nil, '生产面板键位屏蔽了 i')
  assert_true(rhsmap.I ~= nil, '生产面板键位屏蔽了 I')
  assert_true(rhsmap.a ~= nil, '生产面板键位屏蔽了 a')
  assert_true(rhsmap.A ~= nil, '生产面板键位屏蔽了 A')
  callbacks.zR()
  assert_eq(toggle_diff_calls, 1, 'zR 触发右侧 diff 折叠切换')

  -- 左侧面板驱动右侧 diff chunk 跳转：]c / [c 已安装，且无 diff 视图时安全早退（不报错）
  assert_eq(type(callbacks[']c']), 'function', ']c（下一个块）映射已安装')
  assert_eq(type(callbacks['[c']), 'function', '[c（上一个块）映射已安装')
  assert_true(pcall(callbacks[']c']), ']c 在无 diff 视图时安全早退')
  assert_true(pcall(callbacks['[c']), '[c 在无 diff 视图时安全早退')

  -- 鼠标拖拽/多击防 visual：恒装（不再受 right_click 门控；<Nop> 的 rhs 为空串）
  assert_true(rhsmap['<LeftDrag>'] ~= nil, '<LeftDrag> 已 Nop')
  assert_true(rhsmap['<2-LeftMouse>'] ~= nil, '<2-LeftMouse> 已 Nop（防双击选词）')
  assert_true(rhsmap['<3-LeftMouse>'] ~= nil, '<3-LeftMouse> 已 Nop（防三击选行）')
  assert_true(rhsmap['<4-LeftMouse>'] ~= nil, '<4-LeftMouse> 已 Nop（防四击选块）')
  -- 跨窗口拖入/多击兜底：面板 buffer 挂了 ModeChanged 守卫
  local mc = vim.api.nvim_get_autocmds({ event = 'ModeChanged', buffer = buf })
  assert_true(#mc >= 1, '面板缓冲区注册了 ModeChanged 可视模式防护守卫')

  vim.api.nvim_win_set_buf(win, old_buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function test_panel_drives_right_diff_folds()
  local RightView = require('vv-git.right.view')
  local panel_win = vim.api.nvim_get_current_win()
  local panel_buf = vim.api.nvim_win_get_buf(panel_win)
  local diff_buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, {
    'one', 'two', 'three', 'four', 'five', 'six',
  })
  vim.cmd('rightbelow vsplit')
  local diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(diff_win, diff_buf)
  vim.api.nvim_set_option_value('foldmethod', 'manual', { win = diff_win })
  vim.api.nvim_set_option_value('foldenable', true, { win = diff_win })
  vim.api.nvim_win_call(diff_win, function()
    vim.cmd('2,5fold')
    vim.cmd('normal! zM')
  end)

  vim.api.nvim_set_current_win(panel_win)
  local state = { view = { mode = 'single', b_win = diff_win, b_buf = diff_buf } }

  assert_true(RightView.toggle_all_folds(state), 'panel zR 在单列布局找到了右侧 diff')
  assert_eq(vim.api.nvim_get_current_win(), panel_win, '打开 diff 折叠后焦点仍在面板')
  local opened = vim.api.nvim_win_call(diff_win, function() return vim.fn.foldclosed(3) end)
  assert_eq(opened, -1, '第一次 panel zR 展开全部右侧 diff 折叠')

  assert_true(RightView.toggle_all_folds(state), 'panel zR 处理打开中的右侧 diff')
  assert_eq(vim.api.nvim_get_current_win(), panel_win, '关闭 diff 折叠后焦点仍在面板')
  local closed = vim.api.nvim_win_call(diff_win, function() return vim.fn.foldclosed(3) end)
  assert_eq(closed, 2, '第二次 panel zR 关闭全部右侧 diff 折叠')

  vim.api.nvim_set_current_win(diff_win)
  vim.cmd('leftabove vsplit')
  local left_diff_win = vim.api.nvim_get_current_win()
  local left_diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(left_diff_buf, 0, -1, false, {
    'one', 'two', 'three', 'four', 'five', 'six',
  })
  vim.api.nvim_win_set_buf(left_diff_win, left_diff_buf)
  vim.api.nvim_set_option_value('foldmethod', 'manual', { win = left_diff_win })
  vim.api.nvim_set_option_value('foldenable', true, { win = left_diff_win })
  vim.api.nvim_win_call(left_diff_win, function()
    vim.cmd('2,5fold')
    vim.cmd('normal! zM')
  end)

  state.view.a_win = left_diff_win
  state.view.a_buf = left_diff_buf
  vim.api.nvim_set_current_win(panel_win)

  assert_true(RightView.toggle_all_folds(state), 'panel zR 同时定位左右两列 diff')
  assert_eq(vim.api.nvim_get_current_win(), panel_win, '双列切换 diff 时焦点仍在面板')
  local left_opened = vim.api.nvim_win_call(left_diff_win, function() return vim.fn.foldclosed(3) end)
  local right_opened = vim.api.nvim_win_call(diff_win, function() return vim.fn.foldclosed(3) end)
  assert_eq(left_opened, -1, 'panel zR 展开全部左侧 diff 折叠')
  assert_eq(right_opened, -1, 'panel zR 在双列视图展开全部右侧 diff 折叠')

  vim.api.nvim_win_close(left_diff_win, true)
  vim.api.nvim_win_close(diff_win, true)
  pcall(vim.api.nvim_buf_delete, left_diff_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, diff_buf, { force = true })
  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
end

local function test_single_col_disables_folds()
  local InlineDiff = require('vv-git.inline_diff')
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()
  local previous_buf = vim.api.nvim_win_get_buf(win)
  local previous_ufo = package.loaded.ufo
  local detached = 0

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'one', 'two', 'three', 'four', 'five',
  })
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_option_value('foldmethod', 'manual', { win = win })
  vim.api.nvim_set_option_value('foldenable', true, { win = win })
  vim.api.nvim_set_option_value('foldcolumn', '1', { win = win })
  vim.api.nvim_win_call(win, function() vim.cmd('2,4fold') end)

  package.loaded.ufo = {
    detach = function(target)
      if target == buf then detached = detached + 1 end
    end,
  }

  InlineDiff.apply(buf, { 'one' }, { 'one', 'two', 'three', 'four', 'five' }, 1, {
    b_win = win,
    fold_unchanged = false,
  })

  assert_eq(detached, 1, '单列布局禁用折叠会分离 ufo')
  assert_eq(vim.api.nvim_get_option_value('foldenable', { win = win }), false,
    '单列布局禁用时关闭 foldenable')
  assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '0',
    '单列布局禁用时隐藏 foldcolumn')
  assert_eq(vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(3) end), -1,
    '单列布局禁用时清理现有折叠')

  package.loaded.ufo = previous_ufo
  vim.api.nvim_win_set_buf(win, previous_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function test_scratch_buffer_ownership()
  local Buffers = require('vv-git.right.buffers')
  local owned = vim.api.nvim_create_buf(false, true)
  local foreign = vim.api.nvim_create_buf(false, true)
  vim.b[owned].vv_git_scratch = true
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = foreign })

  Buffers.wipe_scratch({ owned, foreign })

  assert_true(not vim.api.nvim_buf_is_valid(owned), 'scratch 清理会删除带标记的缓冲区')
  assert_true(vim.api.nvim_buf_is_valid(foreign),
    'scratch 清理会保留未标记的第三方 wipe 缓冲区')
  vim.api.nvim_buf_delete(foreign, { force = true })
end

-- 无扩展名的可执行文件必须走共享内容探测，并在右栏显示属性而不是原始字节
local function test_binary_info_preview()
  local RightView = require('vv-git.right.view')
  RightView.configure({
    get_config = function()
      return {
        fold_unchanged = true,
        diff_nowrap = false,
        keymap_next_file = false,
        keymap_prev_file = false,
        conflict_result_ratio = 0.5,
        binary = { intercept = true, extensions = {} },
      }
    end,
  })

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  local path = tmpdir .. '/artifact'
  local file = assert(io.open(path, 'wb'))
  file:write(string.char(
    0xcf, 0xfa, 0xed, 0xfe,
    0x0c, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00
  ))
  file:close()
  vim.uv.fs_chmod(path, 493)

  vim.cmd('tabnew')
  local state = {
    tabpage = vim.api.nvim_get_current_tabpage(),
    git_root = tmpdir,
    panel = { main_win = vim.api.nvim_get_current_win() },
  }
  RightView.show(state, {
    is_dir = false,
    relpath = 'artifact',
    xy = '??',
  }, 'unstaged', false, tmpdir)

  assert_true(state.view and state.view.mode == 'single',
    '无扩展名二进制会按单列右侧信息缓冲区渲染')
  local buf = state.view and state.view.b_buf
  local lines = buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
  local text = table.concat(lines, '\n')
  assert_true(text:find('Binary file', 1, true) ~= nil,
    '二进制预览显示英文标题')
  assert_true(text:find('Type: Mach-O 64-bit executable', 1, true) ~= nil,
    '二进制预览显示检测到的可执行文件类型')
  assert_true(text:find('Architecture: arm64', 1, true) ~= nil,
    '二进制预览显示检测到的架构')
  assert_true(text:find('Executable: Yes', 1, true) ~= nil,
    '二进制预览显示可执行权限')
  assert_true(buf and vim.b[buf].vv_git_binary_info == true,
    'binary preview buffer exposes its ownership marker')
  assert_true(buf and vim.b[buf].vv_git_diff_source == nil,
    '二进制信息缓冲区不会作为文本 diff 来源暴露')
  assert_true(buf and vim.bo[buf].readonly and not vim.bo[buf].modifiable,
    '二进制信息缓冲区明确设为只读')
  local highlighted = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    highlighted[mark[4].hl_group] = true
  end
  assert_true(highlighted.VVUtilsFileInfoTitle and highlighted.VVUtilsFileInfoLabel,
    '二进制信息缓冲区应用了共享标题与标签高亮')

  pcall(RightView.close, state)
  vim.cmd('tabclose')
  vim.fn.delete(tmpdir, 'rf')
end

local function test_conflict_winbar_rejects_stale_callback()
  local Conflict = require('vv-git.right.conflict')
  local Git = require('vv-git.git')
  local original_conflict_info = Git.conflict_info
  local pending
  Git.conflict_info = function(_, _, callback) pending = callback end

  local win = vim.api.nvim_get_current_win()
  local original_winbar = vim.api.nvim_get_option_value('winbar', { win = win })
  Conflict.set_winbar(win, {}, 'HEAD', '/tmp/project')
  Conflict.clear_winbar(win)
  pending({ branch = 'main', hash = 'abc123', subject = 'stale title' })

  assert_eq(vim.api.nvim_get_option_value('winbar', { win = win }), '',
    '已清理的冲突 winbar 会拒绝过期异步回调')

  Git.conflict_info = original_conflict_info
  vim.api.nvim_set_option_value('winbar', original_winbar, { win = win, scope = 'local' })
end

local function test_conflict_hunks_stage_after_last_resolution()
  local Conflict = require('vv-git.right.conflict')
  local Git = require('vv-git.git')
  local Loader = require('vv-git.loader')
  local original_stage = Git.stage
  local original_reload = Loader.reload_index
  local stage_calls, reload_calls = {}, 0
  Git.stage = function(root, paths, callback)
    stage_calls[#stage_calls + 1] = { root = root, path = paths[1] }
    callback(true)
  end
  Loader.reload_index = function() reload_calls = reload_calls + 1 end

  local path = vim.fn.tempname()
  vim.fn.writefile({ 'seed' }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'start',
    '<<<<<<< ours',
    'ordinary ours',
    '=======',
    'ordinary theirs',
    '>>>>>>> theirs',
    'middle',
    '<<<<<<< ours',
    'diff3 ours',
    '||||||| base',
    'base content',
    '=======',
    'diff3 theirs',
    '>>>>>>> theirs',
    'end',
  })

  local win = vim.api.nvim_get_current_win()
  local previous_buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)
  local state = {
    git_root = '/fallback',
    view = {
      section = 'conflicts',
      root = '/subrepo',
      node = { relpath = 'conflicted.txt' },
      c_buf = buf,
      c_win = win,
    },
  }
  Conflict.install_keymaps(buf, state)

  local accept_ours
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if mapping.desc == 'vv-git: accept_ours' then accept_ours = mapping.callback end
  end

  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  accept_ours()
  assert_eq(#stage_calls, 0, '接受非最终冲突块时不会暂存')

  vim.api.nvim_win_set_cursor(win, { 5, 0 })
  accept_ours()
  assert_eq(stage_calls[1] and stage_calls[1].root, '/subrepo',
    'final conflict hunk stages through view root')
  assert_eq(stage_calls[1] and stage_calls[1].path, 'conflicted.txt',
    'final conflict hunk stages the current path')
  assert_eq(reload_calls, 1, '最终冲突解决成功后仅重载一次')
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'),
    table.concat({ 'start', 'ordinary ours', 'middle', 'diff3 ours', 'end' }, '\n'),
    'ordinary and diff3 ours resolution excludes markers and base content'
  )

  Git.stage = original_stage
  Loader.reload_index = original_reload
  vim.api.nvim_win_set_buf(win, previous_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

local function test_right_layout_lifecycle()
  local Layout = require('vv-git.right.layout')
  local removed = {}
  local layout = Layout.new({
    conflict_result_ratio = 0.5,
    on_remove_result_buffer = function(buf) removed[#removed + 1] = buf end,
  })

  vim.cmd('tabnew')
  local main_win = vim.api.nvim_get_current_win()
  local state = {
    tabpage = vim.api.nvim_get_current_tabpage(),
    panel = { main_win = main_win },
    view = {},
  }

  local b_win, a_win = layout.ensure(state, true)
  assert_true(vim.api.nvim_win_is_valid(a_win) and vim.api.nvim_win_is_valid(b_win),
    '右侧布局会创建真实双窗口视图')
  state.view.a_win, state.view.b_win = a_win, b_win

  local conflict_b, conflict_a, c_win = layout.ensure_conflict(state)
  assert_eq(conflict_b, b_win, '冲突布局保留主窗口 b')
  assert_true(vim.api.nvim_win_is_valid(conflict_a) and vim.api.nvim_win_is_valid(c_win),
    '冲突布局会创建真实的 ours 与结果窗口')
  assert_true(vim.api.nvim_win_get_position(c_win)[1] > vim.api.nvim_win_get_position(conflict_b)[1],
    'conflict result window is below the dual diff')

  local old_c_buf = vim.api.nvim_create_buf(false, true)
  state.view.a_win, state.view.b_win = conflict_a, conflict_b
  state.view.c_win, state.view.c_buf = c_win, old_c_buf
  vim.api.nvim_win_close(conflict_a, true)

  local rebuilt_b, rebuilt_a, rebuilt_c = layout.ensure_conflict(state)
  assert_eq(rebuilt_b, b_win, '未完成重建冲突时保留主窗口 b')
  assert_true(vim.api.nvim_win_is_valid(rebuilt_a) and vim.api.nvim_win_is_valid(rebuilt_c),
    '不完整的冲突布局会被重建')
  assert_true(not vim.api.nvim_win_is_valid(c_win),
    '重建冲突布局会关闭过期结果窗口')
  assert_eq(#removed, 1, '冲突重建仅释放一次过期结果资源')
  assert_eq(removed[1], old_c_buf, '冲突重建释放过期结果缓冲区')

  local c_buf = vim.api.nvim_create_buf(false, true)
  state.view.a_win, state.view.b_win = rebuilt_a, rebuilt_b
  state.view.c_win, state.view.c_buf = rebuilt_c, c_buf
  local single_b, single_a = layout.ensure(state, false)
  assert_eq(single_b, b_win, '单列布局复用主窗口 b')
  assert_true(single_a == nil and not vim.api.nvim_win_is_valid(rebuilt_a),
    '离开冲突视图会关闭 ours 窗口')
  assert_true(not vim.api.nvim_win_is_valid(rebuilt_c),
    '离开冲突视图会关闭额外布局窗口')
  assert_eq(#removed, 2, '每个冲突结果生命周期仅释放一次')
  assert_eq(removed[2], c_buf, '退出冲突后释放当前结果缓冲区')

  vim.api.nvim_buf_delete(old_c_buf, { force = true })
  vim.api.nvim_buf_delete(c_buf, { force = true })
  vim.cmd('tabclose')
end

local function test_resize_restores_diff_ratio()
  vim.cmd('tabnew')
  local a_win = vim.api.nvim_get_current_win()
  vim.cmd('vsplit')
  local b_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(a_win, 20)

  local before_total = vim.api.nvim_win_get_width(a_win) + vim.api.nvim_win_get_width(b_win)
  require('vv-git.core.panel_ops').apply_diff_ratio({
    view = {
      mode = 'diff2',
      a_win = a_win,
      b_win = b_win,
    },
  }, { 4.5, 5.5 })

  local expected = math.floor(before_total * 4.5 / 10)
  assert_eq(vim.api.nvim_win_get_width(a_win), expected,
    'VimResized 后双栏恢复 diff_ratio')
  assert_eq(vim.api.nvim_win_get_width(a_win) + vim.api.nvim_win_get_width(b_win), before_total,
    '恢复 diff_ratio 不改变 diff 区域总宽度')
  vim.cmd('tabclose')
end

local function test_staged_scrollbar_source()
  local RightView = require('vv-git.right.view')
  local toggle_stage_calls = 0
  RightView.configure({
    on_toggle_stage = function() toggle_stage_calls = toggle_stage_calls + 1 end,
  })
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
  assert_true(ready, '已渲染 staged 右侧 diff 缓冲区')

  local right_maps = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.view.b_buf, 'n')) do
    right_maps[map.lhs] = map.callback
  end
  assert_eq(type(right_maps['-']), 'function', '右侧 diff 缓冲区安装 toggle_stage 映射')
  right_maps['-']()
  assert_eq(toggle_stage_calls, 1, '右侧 diff 中 - 调用 toggle_stage 处理器')

  local reconfigured_calls = 0
  RightView.configure({
    on_toggle_stage = function() reconfigured_calls = reconfigured_calls + 1 end,
  })
  right_maps['-']()
  assert_eq(toggle_stage_calls, 1, '替换映射后不再调用旧处理器')
  assert_eq(reconfigured_calls, 1, '安装映射调用最新配置的处理器')

  local source = ready and vim.b[state.view.b_buf].vv_git_diff_source or nil
  assert_eq(vim.w[state.view.b_win].vv_scrollbar_always_show, true,
    'staged 右侧窗口应持续显示滚动条标记')
  assert_eq(vim.w[state.view.b_win].vv_statuscol_git_disabled, true,
    'vv-git 预览窗口应隐藏 statuscol git 标记')
  assert_eq(source and source.root, tmpdir, 'staged 滚动条来源携带 git root')
  assert_eq(source and source.path, 'sample.txt', 'staged 滚动条来源携带相对路径')
  assert_eq(source and source.mode, 'staged', 'staged 滚动条来源使用缓存 diff')
  assert_eq(source and source.side, 'new', 'staged 已修改文件映射到 index 侧')
  assert_eq(
    vim.b[state.view.b_buf].vv_git_source_path,
    vim.fs.normalize(tmpdir .. '/sample.txt'),
    'staged scratch 缓冲区暴露其工作区文件路径'
  )

  RightView.show(state, { is_dir = false, relpath = 'removed.txt', xy = 'D ' }, 'staged', false, tmpdir)
  local deletion_ready = vim.wait(3000, function()
    return state.view and state.view.path == 'removed.txt'
      and state.view.b_buf and vim.api.nvim_buf_is_valid(state.view.b_buf)
  end)
  assert_true(deletion_ready, 'staged 删除右侧缓冲区已渲染')

  local deletion_source = deletion_ready and vim.b[state.view.b_buf].vv_git_diff_source or nil
  assert_eq(deletion_source and deletion_source.path, 'removed.txt', 'staged 删除项包含相对路径')
  assert_eq(deletion_source and deletion_source.side, 'old', 'staged 删除项落到 HEAD 侧')

  local preview_win = state.view.b_win
  pcall(RightView.close, state)
  assert_eq(vim.w[preview_win].vv_statuscol_git_disabled, nil,
    '关闭 vv-git 会恢复复用窗口的 statuscol Git 标记')

  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'second' })
  state.compare = { from_rev = 'HEAD^', to_rev = 'HEAD' }
  RightView.show(state, {
    is_dir = false,
    relpath = 'sample.txt',
    compare_status = 'M',
  }, 'compare', false, tmpdir)
  local compare_ready = vim.wait(3000, function()
    return state.view and state.view.section == 'compare'
      and state.view.a_buf and vim.api.nvim_buf_is_valid(state.view.a_buf)
      and state.view.b_buf and vim.api.nvim_buf_is_valid(state.view.b_buf)
  end)
  assert_true(compare_ready, '已渲染 revision 对比缓冲区')

  local a_source = compare_ready and vim.b[state.view.a_buf].vv_git_diff_source or nil
  local b_source = compare_ready and vim.b[state.view.b_buf].vv_git_diff_source or nil
  assert_eq(a_source and a_source.from_rev, 'HEAD^', 'compare old source 包含 from_rev')
  assert_eq(a_source and a_source.side, 'old', 'compare old source 落在旧侧')
  assert_eq(b_source and b_source.to_rev, 'HEAD', 'compare new source 包含 to_rev')
  assert_eq(b_source and b_source.side, 'new', 'compare new source 落在新侧')
  assert_eq(vim.w[state.view.a_win].vv_statuscol_git_disabled, nil,
    'compare 旧侧窗口应启用 revision statuscol 标记')
  assert_eq(vim.w[state.view.b_win].vv_statuscol_git_disabled, nil,
    'compare 新侧窗口应启用 revision statuscol 标记')

  local previous_compare_buf = state.view.b_buf
  state.compare = { from_rev = 'HEAD^', to_rev = 'missing-ref' }
  RightView.show(state, {
    is_dir = false,
    relpath = 'sample.txt',
    compare_status = 'M',
  }, 'compare', false, tmpdir)
  local fallback_ready = vim.wait(3000, function()
    return state.view and state.view.mode == 'single'
      and state.view.b_buf ~= previous_compare_buf
      and vim.api.nvim_buf_is_valid(state.view.b_buf)
  end)
  assert_true(fallback_ready, '目标版本加载失败时 compare 回退到源版本')
  local fallback_source = fallback_ready and vim.b[state.view.b_buf].vv_git_diff_source or nil
  assert_eq(fallback_source and fallback_source.side, 'old',
    'compare 回退时复用源版本到旧侧显示')

  pcall(RightView.close, state)
  vim.fn.delete(tmpdir, 'rf')
end

local function test_compare_tag_with_head()
  local Compare = require('vv-git.compare')
  local State = require('vv-git.state')
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
  vim.fn.writefile({ 'v1' }, tmpdir .. '/sample.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'v1' })
  vim.fn.system({ 'git', '-C', tmpdir, 'tag', '-a', 'v1.0.0', '-m', 'release v1' })
  vim.fn.writefile({ 'v2' }, tmpdir .. '/sample.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qam', 'v2' })

  local done = false
  State.clear()
  local state = State.create()
  state.git_root = tmpdir
  Compare.start(state, 'v1.0.0', 'v1.0.0', 'v1.0.0..HEAD', function() done = true end)
  assert_true(vim.wait(3000, function() return done end), 'tag 与 HEAD 对比完成')
  assert_eq(state.compare and state.compare.from_rev, 'v1.0.0', 'tag 作为对比来源 ref 保留')
  assert_eq(state.compare and state.compare.to_rev, 'HEAD', 'tag 对比目标保持为 HEAD')
  assert_eq(state.compare and state.compare.files[1] and state.compare.files[1].path, 'sample.txt',
    'tag..HEAD compare 返回已变更文件')

  done = false
  Compare.start_refs(state, 'v1.0.0', 'HEAD', 'v1.0.0', 'v1.0.0..HEAD', function() done = true end)
  assert_true(vim.wait(3000, function() return done end), '任意 refs 对比完成')
  assert_eq(state.compare and state.compare.from_rev, 'v1.0.0', '任意 refs 保留来源 ref')
  assert_eq(state.compare and state.compare.to_rev, 'HEAD', '任意 refs 保持目标 ref')

  State.clear()
  vim.fn.delete(tmpdir, 'rf')
end

local function test_compare_file_uses_live_buffer()
  local FileCompare = require('vv-git.file_compare')
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
  vim.fn.writefile({ 'committed' }, tmpdir .. '/sample.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })

  vim.cmd('edit ' .. vim.fn.fnameescape(tmpdir .. '/sample.txt'))
  local source_buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local source_tab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'unsaved' })

  local original_q_called = false
  local original_escape_called = false
  vim.keymap.set('n', 'q', function() original_q_called = true end, {
    buffer = source_buf,
    desc = 'original q mapping',
  })
  vim.keymap.set('n', '<Esc>', function() original_escape_called = true end, {
    buffer = source_buf,
    desc = 'original escape mapping',
  })

  local closed = false
  local ready_context
  FileCompare.open('HEAD', {
    bufnr = source_buf,
    on_ready = function(context) ready_context = context end,
    on_close = function() closed = true end,
  })

  local ref_buf
  assert_true(vim.wait(3000, function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find('/HEAD/sample.txt', 1, true) then ref_buf = buf end
    end
    return ref_buf ~= nil
  end), 'file compare 打开请求的 revision 缓冲区')
  assert_true(vim.wait(1000, function() return ready_context ~= nil end),
    'file compare 调用就绪回调')
  assert_eq(ready_context.root, vim.uv.fs_realpath(tmpdir), 'file compare 就绪上下文携带 root')
  assert_eq(ready_context.ref, 'HEAD', 'file compare 就绪上下文携带引用')

  assert_eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)[1], 'unsaved',
    'file compare 包含未保存缓冲区行')
  assert_eq(vim.api.nvim_buf_get_lines(ref_buf, 0, -1, false)[1], 'committed',
    'file compare 加载请求的引用')

  local diff_windows = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_get_option_value('diff', { win = win }) then diff_windows = diff_windows + 1 end
  end
  assert_eq(diff_windows, 2, 'file compare 打开原生双列 diff')

  local close_map
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(source_buf, 'n')) do
    if map.lhs == 'q' then close_map = map; break end
  end
  assert_true(close_map and type(close_map.callback) == 'function', 'file compare 安装 q 关闭回调')
  close_map.callback()
  assert_true(vim.wait(1000, function() return closed end), '文件 compare 调用了关闭回调')
  assert_eq(vim.api.nvim_get_current_tabpage(), source_tab, '文件 compare 返回源 tab')
  assert_true(vim.api.nvim_win_is_valid(source_win), '文件 compare 保留源窗口')
  assert_eq(vim.api.nvim_get_option_value('diff', { win = source_win }), false,
    'file compare 恢复源窗口 diff 选项')

  local restored_maps = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(source_buf, 'n')) do
    restored_maps[map.lhs] = map
  end
  assert_eq(restored_maps.q and restored_maps.q.desc, 'original q mapping',
    'file compare 恢复原始 q 映射')
  assert_eq(restored_maps['<Esc>'] and restored_maps['<Esc>'].desc, 'original escape mapping',
    'file compare 恢复原始 Escape 映射')
  restored_maps.q.callback()
  restored_maps['<Esc>'].callback()
  assert_true(original_q_called, '恢复的 q 映射仍可调用')
  assert_true(original_escape_called, '恢复的 Escape 映射仍可调用')

  local compare_error
  local closed_after_error = false
  FileCompare.open('missing-ref', {
    bufnr = source_buf,
    on_error = function(message) compare_error = message end,
    on_close = function() closed_after_error = true end,
  })
  assert_true(vim.wait(3000, function() return compare_error ~= nil end),
    'file compare 在无法加载 ref 时调用错误回调')
  assert_true(compare_error:find('missing%-ref') ~= nil, 'file compare 错误可识别缺失引用')
  assert_true(not closed_after_error, '未打开视图时 file compare 不会触发 close 回调')

  pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
  vim.fn.delete(tmpdir, 'rf')
end

local function test_panel_action_keys_are_highlighted()
  local Tree = require('vv-git.tree')
  local Render = require('vv-git.left.render')
  local Panel = require('vv-git.left.panel')
  local root = '/tmp/vv-git-panel-key-test'
  local tree = Tree.build({ [root .. '/sample.txt'] = 'M ' }, root)
  local lines, extmarks = Render.build({
    git_root = root,
    branch = 'main',
    tree = tree,
    folds = {},
    section_folds = {},
    selection = {},
    repo_info = {
      branch = 'main', branch_name = 'main', head = 'abc123',
      detached = false, unborn = false, remotes = { 'origin' },
      upstream = 'origin/main', ahead = 1, behind = 2,
    },
  })

  local highlighted = {}
  for _, mark in ipairs(extmarks) do
    if mark.opts and mark.opts.hl_group == 'VVGitPanelKey' then
      highlighted[lines[mark.row + 1]:sub(mark.col + 1, mark.opts.end_col)] = true
    end
  end

  assert_true(highlighted.c == true, 'commit 操作键使用 VVGitPanelKey 高亮')
  assert_true(highlighted.p == true, 'push 操作键使用 VVGitPanelKey 高亮')
  assert_true(highlighted.P == true, 'pull 操作键保留大写 P')
  assert_true(vim.tbl_contains(lines, '  c  Commit 1 staged file'), 'commit 提示使用小写 c 键')
  assert_true(vim.tbl_contains(lines, '  p  Push 1 commit'), '单条提交显示单数名词')
  assert_true(vim.tbl_contains(lines, '  P  Pull 2 commits'), '多条提交显示复数名词')
  assert_true(not table.concat(lines, '\n'):find('commit%(s%)'), '面板不会渲染括号复数占位符')

  local panel_buf = Panel.create_buf()
  Panel.flush(panel_buf, lines, extmarks, Render.ns)
  local key_priority
  local hint_priority
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf, Render.ns, 0, -1, { details = true })) do
    local details = mark[4]
    if details.hl_group == 'VVGitPanelKey' then key_priority = details.priority end
    if details.hl_group == 'VVGitCommitHint' then hint_priority = details.priority end
  end
  assert_true(key_priority and hint_priority and key_priority > hint_priority,
    '操作键高亮应高于整行提示高亮')
  Panel.wipe_buf(panel_buf)

  local compare_lines, compare_marks = Render.build({
    git_root = root,
    branch = 'main',
    folds = {},
    compare = { files = {}, label = 'HEAD~..HEAD' },
  })
  local escape_highlighted = false
  for _, mark in ipairs(compare_marks) do
    if mark.opts and mark.opts.hl_group == 'VVGitPanelKey' then
      local text = compare_lines[mark.row + 1]:sub(mark.col + 1, mark.opts.end_col)
      if text == '<Esc>' then escape_highlighted = true end
    end
  end
  assert_true(escape_highlighted, 'compare 退出键使用 VVGitPanelKey 高亮')
end

local function test_repo_info_parser_and_publish()
  local Git = require('vv-git.git')
  local parsed = assert(Git._parse_repo_info(table.concat({
    '# branch.oid abcdef1234567890',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +1 -2',
  }, '\n'), 'backup\norigin\n'))
  assert_eq(parsed.branch_name, 'main', 'repo info 解析分支名')
  assert_eq(parsed.upstream, 'origin/main', 'repo info 解析上游')
  assert_eq(parsed.ahead, 1, 'repo info 解析领先数量')
  assert_eq(parsed.behind, 2, 'repo info 解析落后数量')
  assert_eq(table.concat(parsed.remotes, ','), 'backup,origin', 'repo info 解析并排序远端')

  local unborn = assert(Git._parse_repo_info(table.concat({
    '# branch.oid (initial)',
    '# branch.head main',
  }, '\n'), ''))
  assert_true(unborn.unborn, 'repo info 检测到未初始化分支')
  assert_true(unborn.head == nil, 'unborn 分支未设置 HEAD')

  local detached = assert(Git._parse_repo_info(table.concat({
    '# branch.oid abcdef1234567890',
    '# branch.head (detached)',
  }, '\n'), 'origin\n'))
  assert_true(detached.detached, 'repo info 检测到 detached HEAD')
  assert_eq(detached.branch, 'abcdef1', 'detached 分支使用短哈希显示')

  local tmpdir = vim.fn.tempname()
  local remote = vim.fn.tempname() .. '.git'
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.system({ 'git', '-C', tmpdir, 'init', '-b', 'main' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'vv-git@example.test' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
  vim.fn.writefile({ 'hello' }, tmpdir .. '/sample.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })
  vim.fn.system({ 'git', 'init', '--bare', remote })

  local added
  Git.add_remote(tmpdir, 'origin', remote, function(ok) added = ok end)
  assert_true(vim.wait(3000, function() return added ~= nil end), 'add_remote 回调完成')
  assert_true(added, 'add_remote 执行成功')

  local published
  Git.publish(tmpdir, 'origin', function(ok) published = ok end)
  assert_true(vim.wait(3000, function() return published ~= nil end), 'publish 回调完成')
  assert_true(published, 'publish 在本地 bare 仓库中成功')

  local info
  Git.repo_info(tmpdir, function(value) info = value end)
  assert_true(vim.wait(3000, function() return info ~= nil end), 'repo_info 回调完成')
  assert_eq(info.upstream, 'origin/main', 'publish 已建立上游')
  assert_eq(info.ahead, 0, '已发布分支未领先')

  vim.fn.delete(tmpdir, 'rf')
  vim.fn.delete(remote, 'rf')
end

local function test_public_api_contract()
  local Plugin = require('vv-git')
  local State = require('vv-git.state')
  local Subrepo = require('vv-git.subrepo')
  local state = State.create()
  state.git_root = '/repo'
  state.selection = {
    [Subrepo.sel_key('staged', 'same.lua')] = true,
    [Subrepo.sel_key('unstaged', 'same.lua')] = true,
    [Subrepo.sel_key(Subrepo.section_id('/repo/sub', '/repo', 'unstaged'), 'nested.lua')] = true,
  }
  assert_eq(
    table.concat(Plugin.get_target_paths(), '\n'),
    '/repo/same.lua\n/repo/sub/nested.lua',
    '目标路径会解析子仓库并去重后按绝对路径排序'
  )
  State.clear()

  local config_copy = Plugin.config()
  local configured_width = config_copy.width
  config_copy.width = -1
  assert_eq(Plugin.config().width, configured_width, 'config 返回隔离副本')

  local depth_ok = Plugin.set_subrepo_depth(2)
  assert_true(depth_ok, '公开的 subrepo depth 接受非负整数')
  assert_eq(Plugin.get_subrepo_depth(), 2, '公开的 subrepo depth 读取覆盖值')
  local invalid_depth = Plugin.set_subrepo_depth(-1)
  assert_true(not invalid_depth, '公开的 subrepo depth 拒绝负数')
  Plugin.set_subrepo_depth(0)

  local before_open_calls = 0
  local resume_after_close_calls = 0
  Plugin.setup({
    before_open = function()
      before_open_calls = before_open_calls + 1
      return function() resume_after_close_calls = resume_after_close_calls + 1 end
    end,
    keymap_toggle_panel = false,
    auto_refresh = false,
    preview = false,
    subrepo = { depth = 0 },
  })

  for _, command in ipairs({
    'VVGit', 'VVGitClose', 'VVGitToggle', 'VVGitTogglePanel', 'VVGitRefresh',
    'VVGitCompare', 'VVGitCompareRef', 'VVGitCompareRefs', 'VVGitCompareFile',
    'VVGitCompareStop', 'VVGitCommitShow', 'VVGitWorktree', 'VVGitPublish',
    'VVGitShow', 'VVGitSubrepoDepth', 'VVGitLoad',
  }) do
    assert_eq(vim.fn.exists(':' .. command), 2, 'setup 注册命令：:' .. command)
  end

  local invalid_error
  local invalid_open = Plugin.open({
    root = '/vv-git/not-a-repository',
    on_error = function(message) invalid_error = message end,
  })
  assert_true(not invalid_open, 'root-aware open 拒绝非仓库路径')
  assert_true(vim.wait(1000, function() return invalid_error ~= nil end),
    'root-aware open 已触发错误回调')
  assert_eq(before_open_calls, 0, '无效 root 不触发 before_open')

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
  vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
  vim.fn.writefile({ 'committed' }, tmpdir .. '/sample.txt')
  vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
  vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })
  vim.fn.writefile({ 'changed' }, tmpdir .. '/sample.txt')

  local ready_context, close_context, goto_context, open_error
  local opened = Plugin.open({
    root = tmpdir,
    path = 'sample.txt',
    on_ready = function(context) ready_context = context end,
    on_error = function(message) open_error = message end,
    on_close = function(context) close_context = context end,
    on_goto_file = function(context) goto_context = context end,
  })
  assert_true(opened, 'root-aware open 启动显式仓库')
  assert_eq(before_open_calls, 1, '首次 open 只触发一次')
  assert_true(vim.wait(3000, function() return ready_context ~= nil end),
    'root-aware open 调用就绪回调')
  assert_true(open_error == nil, 'root-aware open 不会报告伪错误')
  assert_true(Plugin.is_open(), 'is_open 返回活跃 vv-git tab')
  assert_eq(ready_context.root, vim.uv.fs_realpath(tmpdir), 'open context 携带标准化 root')
  assert_eq(ready_context.path, 'sample.txt', 'open context 携带请求路径')
  assert_eq(ready_context.mode, 'workspace', 'open context 报告 workspace 模式')

  local panel_buf = State.get().panel.buf
  local goto_map
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(panel_buf, 'n')) do
    if mapping.lhs == 'gf' then goto_map = mapping; break end
  end
  assert_true(goto_map and type(goto_map.callback) == 'function', 'panel 安装 gf 跳转回调')
  goto_map.callback()
  assert_true(vim.wait(1000, function() return goto_context ~= nil end), '自定义 gf 策略收到文件上下文')
  assert_eq(goto_context.root, vim.uv.fs_realpath(tmpdir), 'gf context 携带仓库 root')
  assert_eq(goto_context.path, 'sample.txt', 'gf context 携带仓库相对路径')
  assert_eq(goto_context.abspath, vim.uv.fs_realpath(tmpdir) .. '/sample.txt', 'gf context 携带绝对路径')
  assert_true(Plugin.is_open(), '自定义 gf 策略保留 vv-git tab')
  assert_true(close_context == nil, '自定义 gf 策略不触发 close 回调')

  Plugin.toggle_panel()
  assert_true(Plugin.is_open(), '隐藏面板后 vv-git tab 保持打开')
  assert_true(close_context == nil, '隐藏面板不触发 close 回调')
  Plugin.toggle_panel()

  local compare_context, compare_error
  assert_true(Plugin.compare_refs('HEAD', 'HEAD', {
    root = tmpdir,
    on_ready = function(context) compare_context = context end,
    on_error = function(message) compare_error = message end,
  }), 'public compare_refs 使用显式 root 启动')
  assert_true(vim.wait(3000, function() return compare_context ~= nil end),
    'public compare_refs 调用就绪回调')
  assert_true(compare_error == nil, 'public compare_refs 不会返回伪错误')
  assert_eq(compare_context.mode, 'compare', 'compare context 报告 compare 模式')
  assert_eq(compare_context.from_ref, 'HEAD', 'compare context 携带来源 ref')
  assert_eq(compare_context.to_ref, 'HEAD', 'compare context 携带目标 ref')
  assert_true(Plugin.stop_compare(), 'stop_compare 结束进行中的对比')
  assert_eq(Plugin.get_context().mode, 'workspace', 'stop_compare 恢复 workspace context')

  local revision_error
  assert_true(Plugin.compare_refs('missing-ref', 'HEAD', {
    root = tmpdir,
    on_error = function(message) revision_error = message end,
  }), 'public compare_refs 接受异步比较请求')
  assert_true(vim.wait(3000, function() return revision_error ~= nil end),
    'public compare_refs 为无效引用调用错误回调')
  assert_true(revision_error:find('missing%-ref') ~= nil,
    'public compare_refs 错误可识别无效引用')

  Plugin.close()
  assert_true(vim.wait(1000, function() return close_context ~= nil end),
    '关闭 vv-git tab 时会触发 close 回调')
  assert_true(not Plugin.is_open(), 'vv-git tab 关闭后 is_open 为 false')
  assert_eq(close_context.root, vim.uv.fs_realpath(tmpdir), 'close context 保留仓库 root')
  assert_true(vim.wait(1000, function() return resume_after_close_calls == 1 end),
    '关闭 vv-git 时仅触发一次匹配的 resume 回调')

  vim.fn.delete(tmpdir, 'rf')
end

-- 执行所有测试
log('========== vv-git.nvim 变更验证 ==========')
test_discard_untracked_file()
test_discard_untracked_dir()
test_unstage_without_head()
test_unstage_with_head()
test_panel_edge_file_keymaps()
test_panel_drives_right_diff_folds()
test_single_col_disables_folds()
test_scratch_buffer_ownership()
test_binary_info_preview()
test_conflict_winbar_rejects_stale_callback()
test_conflict_hunks_stage_after_last_resolution()
test_right_layout_lifecycle()
test_resize_restores_diff_ratio()
test_staged_scrollbar_source()
test_compare_tag_with_head()
test_compare_file_uses_live_buffer()
test_panel_action_keys_are_highlighted()
test_repo_info_parser_and_publish()
test_public_api_contract()
log('========== 测试完成 ==========')
print(string.format('总计: %d 通过, %d 失败', _passed, _failed))
if _failed > 0 then os.exit(1) end
