-- 变更树目录节点的属性预览：右侧显示该目录下的变更文件数与状态分布
--
-- 目录不是文件，走的是「没有 a/b 两版可比」的单栏路径。这里守住三件事：
--   ① 目录节点确实能 attach，且内容是聚合统计而不是某个文件的 diff
--   ② 统计只覆盖该子树，父目录与兄弟目录不串
--   ③ 目录视图不污染按文件工作的动作（cur_path / gf）

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local repo = vim.fn.tempname()
vim.fn.mkdir(repo .. '/src/deep', 'p')
vim.fn.mkdir(repo .. '/docs', 'p')

local function git(args)
  local command = { 'git', '-C', repo }
  vim.list_extend(command, args)
  local output = vim.fn.system(command)
  assert(vim.v.shell_error == 0, output)
  return output
end

git({ 'init', '-q' })
git({ 'config', 'user.name', 'vv-git test' })
git({ 'config', 'user.email', 'test@example.com' })
vim.fn.writefile({ 'a1' }, repo .. '/src/a.txt')
vim.fn.writefile({ 'b1' }, repo .. '/src/deep/b.txt')
vim.fn.writefile({ 'gone' }, repo .. '/src/gone.txt')
vim.fn.writefile({ 'd1' }, repo .. '/docs/d.txt')
git({ 'add', '-A' })
git({ 'commit', '-qm', 'initial' })

-- src/ 下：1 改 + 1 删 + 1 新增未跟踪；docs/ 下：1 改
vim.fn.writefile({ 'a2' }, repo .. '/src/a.txt')
vim.fn.delete(repo .. '/src/gone.txt')
vim.fn.writefile({ 'fresh' }, repo .. '/src/new.txt')
vim.fn.writefile({ 'd2' }, repo .. '/docs/d.txt')

local Plugin = require('vv-git')
local State = require('vv-git.state')
local Tree = require('vv-git.tree')
local RightView = require('vv-git.right.view')
local DirSummary = require('vv-git.right.dir_summary')

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('  PASS: ' .. name)
  else
    failed = failed + 1
    print('  FAIL: ' .. name .. ' -> ' .. tostring(err))
  end
end

Plugin.setup({ preview = true, preview_debounce_ms = 0, auto_refresh = false })

local ready, open_error
assert(Plugin.open({
  root = repo,
  on_ready = function() ready = true end,
  on_error = function(err) open_error = err end,
}))
assert(vim.wait(5000, function() return ready end), open_error or 'repository did not open')

local state = State.get()

---@param side_root table
---@param relpath string
---@return table
local function dir_at(side_root, relpath)
  local cur = side_root
  for _, part in ipairs(vim.split(relpath, '/', { plain = true })) do
    cur = cur.children and cur.children[part]
    assert(cur, 'directory node not found: ' .. relpath)
  end
  assert(cur.is_dir, relpath .. ' should be a directory node')
  return cur
end

---@return string
local function view_text()
  local buf = state.view and state.view.b_buf
  assert(buf and vim.api.nvim_buf_is_valid(buf), 'right view has no buffer')
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

print('\n=== vv-git 目录预览 ===\n')

test('目录节点渲染为聚合统计而不是 diff', function()
  local node = dir_at(state.tree.unstaged, 'src')
  RightView.show(state, node, 'unstaged', false, state.git_root)
  assert(vim.wait(3000, function()
    return state.view and state.view.path == 'src'
  end), 'src 目录没有 attach 到右侧')

  assert(state.view.mode == 'single', '目录只有一侧内容，必须走单栏')
  assert(state.view.intrinsic_single, '目录视图应标记为固有单栏，避免 resize 时被重排成 dual')
  assert(vim.b[state.view.b_buf].vv_git_scratch, '目录预览必须用 vv-git 自建 scratch')

  local text = view_text()
  assert(text:find('Directory', 1, true), '缺少目录标题: ' .. text)
  assert(text:find('Path: src', 1, true), '缺少目录路径: ' .. text)
  assert(text:find('Changes: 3 files', 1, true), 'src 下应有 3 个变更文件: ' .. text)
  assert(text:find('Modified: 1', 1, true), '缺少 Modified 分项: ' .. text)
  assert(text:find('Deleted: 1', 1, true), '缺少 Deleted 分项: ' .. text)
  assert(text:find('Untracked: 1', 1, true), '缺少 Untracked 分项: ' .. text)
end)

test('统计只覆盖自己的子树', function()
  local node = dir_at(state.tree.unstaged, 'docs')
  RightView.show(state, node, 'unstaged', false, state.git_root)
  assert(vim.wait(3000, function()
    return state.view and state.view.path == 'docs'
  end), 'docs 目录没有 attach 到右侧')

  local text = view_text()
  assert(text:find('Changes: 1 file', 1, true), 'docs 下只有 1 个变更文件: ' .. text)
  assert(not text:find('Untracked', 1, true), 'docs 不该混进 src 的未跟踪文件: ' .. text)
end)

test('嵌套目录按子树聚合，父目录含全部后代', function()
  local nested = Tree.count_status(dir_at(state.tree.unstaged, 'src'))
  assert(nested.total == 3, 'src 子树应有 3 个变更文件，实际 ' .. nested.total)
  assert(nested.letters['M'] == 1 and nested.letters['D'] == 1 and nested.letters['?'] == 1,
    '状态分布不正确: ' .. vim.inspect(nested.letters))
end)

test('面板光标移到目录行会预览，且不改写当前文件选择', function()
  -- 先让光标停在一个文件行上，确立一个「当前文件」
  local file_lnum, dir_lnum
  for lnum, id in pairs(state.panel.id_by_line or {}) do
    if id.node and id.node.relpath == 'src/a.txt' then file_lnum = lnum end
    if id.node and id.node.is_dir and id.node.relpath == 'src' then dir_lnum = lnum end
  end
  assert(file_lnum and dir_lnum, '面板里没有同时找到 src 目录行与 src/a.txt 文件行')

  local function move_to(lnum)
    vim.api.nvim_set_current_win(state.panel.win)
    vim.api.nvim_win_set_cursor(state.panel.win, { lnum, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = state.panel.buf })
  end

  move_to(file_lnum)
  assert(vim.wait(3000, function()
    return state.view and state.view.path == 'src/a.txt'
  end), '文件行没有触发预览')
  assert(state.cur_path == 'src/a.txt', '文件预览应把它设为当前文件')

  move_to(dir_lnum)
  assert(vim.wait(3000, function()
    return state.view and state.view.path == 'src'
  end), '目录行没有触发预览')
  assert(view_text():find('Changes: 3 files', 1, true), '目录行预览内容不正确')
  assert(state.cur_path == 'src/a.txt', '目录预览不应把当前文件改成一个目录')
end)

test('未知状态码不会被统计吞掉', function()
  local node = {
    is_dir = true,
    relpath = 'weird',
    children = {
      ['x.txt'] = { is_dir = false, relpath = 'weird/x.txt', letter = 'Z' },
      ['y.txt'] = { is_dir = false, relpath = 'weird/y.txt', letter = 'M' },
    },
  }
  local text = table.concat(DirSummary.lines(node, 'weird'), '\n')
  assert(text:find('Changes: 2 files', 1, true), '总数应包含未知状态: ' .. text)
  assert(text:find('Modified: 1', 1, true), '已知状态应正常分项: ' .. text)
  assert(text:find('Other: 1', 1, true), '未知状态应归入 Other，避免分项对不上总数: ' .. text)
end)

pcall(vim.cmd, 'tabclose')
vim.fn.delete(repo, 'rf')

print('\n' .. string.rep('─', 50))
print(('共 %d 项: %d 通过, %d 失败'):format(passed + failed, passed, failed))
if failed > 0 then
  print('存在失败项')
  vim.cmd('cquit 1')
end
print('vv-git dir preview: PASS')
