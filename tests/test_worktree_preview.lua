-- worktree_preview：浏览时右侧用只读快照，进入 b_win 时原地换成真实 buffer
--   ① snapshot 预览不加载真实文件（不触发 BufRead / LSP 链路）
--   ② 进入 b_win 后换成真实 buffer，且 FileType 链真的跑了（vim.lsp.enable 靠 FileType
--      attach，缺了它 gd / K 失效）；光标位置保持
--   ③ 焦点本就在 b_win 时直接给真实 buffer；已加载的文件直接复用（可能带未保存修改）
--   ④ 函数配置拿到上下文并决定模式；单栏 inline 换真实 buffer 后挂 live diff
--   ⑤ snapshot_promote_ms：停留后自动换真实 buffer 且焦点留在左栏；快速连切时途经文件不加载
-- 用法: cd vv-git.nvim && nvim --headless -u NONE -l tests/test_worktree_preview.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)
vim.cmd('filetype on')

vim.o.columns = 220
vim.o.lines = 50

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, 'p')

local function git(args)
  local command = { 'git', '-C', repo }
  vim.list_extend(command, args)
  local output = vim.fn.system(command)
  assert(vim.v.shell_error == 0, output)
  return output
end

local base = {}
for i = 1, 60 do base[i] = 'local v' .. i .. ' = ' .. i end
git({ 'init', '-q' })
git({ 'config', 'user.name', 'vv-git test' })
git({ 'config', 'user.email', 'test@example.com' })
local NAMES = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' }
for _, name in ipairs(NAMES) do vim.fn.writefile(base, repo .. '/' .. name .. '.lua') end
git({ 'add', '-A' })
git({ 'commit', '-qm', 'initial' })

local changed = vim.deepcopy(base)
changed[40] = 'local v40 = "changed"'
for _, name in ipairs(NAMES) do vim.fn.writefile(changed, repo .. '/' .. name .. '.lua') end

local Plugin = require('vv-git')
local State = require('vv-git.state')
local RightView = require('vv-git.right.view')

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

Plugin.setup({ preview = false, auto_refresh = false, worktree_preview = 'snapshot' })

local ready, open_error
assert(Plugin.open({
  root = repo,
  on_ready = function() ready = true end,
  on_error = function(err) open_error = err end,
}))
assert(vim.wait(5000, function() return ready end), open_error or '仓库未打开')

local state = State.get()

---@param mode VVGitWorktreePreview|function
---@param promote_ms? integer|false
local function use_mode(mode, promote_ms)
  local cfg = Plugin.config()
  cfg.worktree_preview = mode
  cfg.snapshot_promote_ms = promote_ms or false
  RightView.configure({ get_config = function() return cfg end })
end

---@param relpath string
---@return table
local function unstaged_node(relpath)
  for _, id in pairs(state.panel.id_by_line) do
    if id.node and id.node.relpath == relpath and id.section == 'unstaged' then return id.node end
  end
  error('unstaged 节点不存在: ' .. relpath)
end

---@param relpath string
---@param force_single? boolean
local function show(relpath, force_single)
  RightView.show(state, unstaged_node(relpath), 'unstaged', force_single, state.git_root)
  assert(vim.wait(3000, function()
    return state.view and state.view.path == relpath and state.view._show_req_id == state._show_req_id
  end, 10), relpath .. ' 预览未挂载')
  vim.wait(30) -- schedule_diff_sync
end

-- repo 是 tempname（macOS 下为 /var 软链接），vv-git 的仓库根已解析为 /private/var 实路径
local function abspath(relpath) return state.git_root .. '/' .. relpath end

test('snapshot 预览不加载真实文件', function()
  vim.api.nvim_set_current_win(state.panel.win)
  show('a.lua')
  local view = state.view
  assert(view.mode == 'diff2', '修改文件应为双栏')
  assert(view.b_snapshot and vim.b[view.b_buf].vv_git_snapshot, 'b 侧应为快照')
  assert(vim.bo[view.b_buf].buftype == 'nowrite', '快照必须是 nowrite，vim.lsp.enable 才会跳过')
  assert(vim.fn.bufloaded(abspath('a.lua')) == 0, '快照预览不应加载真实文件')
end)

test('进入 b_win 原地换成真实 buffer，FileType 链生效且光标保持', function()
  local view = state.view
  local snapshot = view.b_buf
  vim.api.nvim_win_set_cursor(view.b_win, { 40, 6 })

  local filetype_fired = false
  local au = vim.api.nvim_create_autocmd('FileType', {
    callback = function(args)
      if vim.api.nvim_buf_get_name(args.buf) == abspath('a.lua') then filetype_fired = true end
    end,
  })
  vim.api.nvim_set_current_win(view.b_win)
  vim.api.nvim_del_autocmd(au)

  local real = vim.fn.bufnr(abspath('a.lua'))
  assert(state.view.b_buf == real and not state.view.b_snapshot, 'b 侧未换成真实 buffer')
  assert(vim.api.nvim_win_get_buf(view.b_win) == real, 'b_win 未显示真实 buffer')
  assert(vim.bo[real].buftype == '', '真实 buffer 应为普通文件')
  assert(filetype_fired, '真实 buffer 的 FileType 未触发：LSP 不会 attach')
  assert(not vim.api.nvim_buf_is_valid(snapshot), '快照应被释放')
  local cursor = vim.api.nvim_win_get_cursor(view.b_win)
  assert(cursor[1] == 40 and cursor[2] == 6, '光标位置未保持: ' .. vim.inspect(cursor))
  assert(RightView.is_attached_current(state), '换 buffer 后 view 不应过期')
end)

test('焦点在 b_win 时切文件直接给真实 buffer', function()
  assert(vim.api.nvim_get_current_win() == state.view.b_win, '前置条件：焦点在 b_win')
  show('b.lua')
  assert(not state.view.b_snapshot, '焦点在 b_win 时不应给快照')
  assert(state.view.b_buf == vim.fn.bufnr(abspath('b.lua')), 'b 侧应为真实 buffer')
end)

test('已加载的文件直接复用真实 buffer', function()
  vim.api.nvim_set_current_win(state.panel.win)
  local buf = vim.fn.bufadd(abspath('c.lua'))
  vim.fn.bufload(buf)
  show('c.lua')
  assert(state.view.b_buf == buf and not state.view.b_snapshot, '已加载文件不应给快照')
end)

test('函数配置按上下文决定模式', function()
  local seen
  use_mode(function(ctx)
    seen = ctx
    return ctx.path == 'd.lua' and 'buffer' or 'snapshot'
  end)
  vim.api.nvim_set_current_win(state.panel.win)
  show('d.lua')
  assert(seen and seen.path == 'd.lua' and seen.section == 'unstaged' and seen.xy == ' M'
    and seen.abspath == abspath('d.lua') and seen.root == state.git_root and type(seen.size) == 'number',
    '上下文不完整: ' .. vim.inspect(seen))
  assert(not state.view.b_snapshot, '函数返回 buffer 时应加载真实文件')
end)

test('单栏 inline 快照换真实 buffer 后挂 live diff', function()
  use_mode('snapshot')
  vim.api.nvim_set_current_win(state.panel.win)
  show('e.lua', true)
  assert(state.view.mode == 'single' and state.view.b_snapshot, '单栏应为快照')
  vim.api.nvim_set_current_win(state.view.b_win)
  assert(state.view.b_buf == vim.fn.bufnr(abspath('e.lua')), '单栏未换成真实 buffer')
  assert(type(state.view._inline_cleanup) == 'function', '真实 buffer 未挂 live inline diff')
end)

test('停留 snapshot_promote_ms 后自动换真实 buffer，焦点留在左栏', function()
  use_mode('snapshot', 150)
  vim.api.nvim_set_current_win(state.panel.win)
  show('f.lua')
  assert(state.view.b_snapshot, '刚挂载时应仍是快照')
  assert(vim.wait(2000, function() return not state.view.b_snapshot end, 10), '停留后未自动换真实 buffer')
  assert(state.view.b_buf == vim.fn.bufnr(abspath('f.lua')), 'b 侧不是 f.lua 的真实 buffer')
  assert(vim.api.nvim_win_get_buf(state.view.b_win) == state.view.b_buf, 'b_win 未显示真实 buffer')
  assert(vim.api.nvim_get_current_win() == state.panel.win, '自动替换不应抢走左栏焦点')
  assert(RightView.is_attached_current(state), '自动替换后 view 不应过期')
end)

test('快速连切时途经的文件不会被自动加载', function()
  use_mode('snapshot', 300)
  vim.api.nvim_set_current_win(state.panel.win)
  show('g.lua')
  show('h.lua')
  assert(vim.wait(2000, function() return not state.view.b_snapshot end, 10), '最终停留的文件未自动替换')
  vim.wait(400)
  assert(state.view.path == 'h.lua' and state.view.b_buf == vim.fn.bufnr(abspath('h.lua')), '替换目标错误')
  assert(vim.fn.bufloaded(abspath('g.lua')) == 0, '途经的 g.lua 被加载了')
end)

pcall(Plugin.close)
vim.fn.delete(repo, 'rf')

print(string.format('\n%d passed, %d failed', passed, failed))
if failed > 0 then vim.cmd('cquit 1') end
vim.cmd('qa!')
