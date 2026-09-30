-- 回归：j/k 预览切文件时的两处自触发
--   ① 双栏 → 单栏：layout 关 a_win 时旧 view 仍登记着它，WinClosed 把整个 view 当成被外部
--      关闭而 RightView.close，废弃了正在 attach 的 show → 新 view 永远不是「当前」，
--      之后 GitSignsChanged 等被动 reshow 全部失效
--   ② 预览未加载的工作区文件：bufload 在 autocmd 临时窗口发 BufEnter，被 auto_refresh
--      当成进入外部 buffer，每切一个文件就跑一轮 reload_index
-- 用法: cd vv-git.nvim && nvim --headless -u NONE -l tests/test_preview_switch.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

-- 默认 80 列会触发窄屏单栏降级，拿不到双栏 → 单栏的切换
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

git({ 'init', '-q' })
git({ 'config', 'user.name', 'vv-git test' })
git({ 'config', 'user.email', 'test@example.com' })
vim.fn.writefile({ 'a1' }, repo .. '/a.txt')
vim.fn.writefile({ 'b1' }, repo .. '/b.txt')
git({ 'add', '-A' })
git({ 'commit', '-qm', 'initial' })

vim.fn.writefile({ 'a2' }, repo .. '/a.txt')
vim.fn.writefile({ 'b2' }, repo .. '/b.txt')
vim.fn.writefile({ 'fresh' }, repo .. '/new.txt')

local Plugin = require('vv-git')
local State = require('vv-git.state')
local Loader = require('vv-git.loader')
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

Plugin.setup({ preview = true, preview_debounce_ms = 0, auto_refresh = true })

local ready, open_error
assert(Plugin.open({
  root = repo,
  on_ready = function() ready = true end,
  on_error = function(err) open_error = err end,
}))
assert(vim.wait(5000, function() return ready end), open_error or '仓库未打开')

local state = State.get()

---@param relpath string
---@return table
local function unstaged_node(relpath)
  for _, id in pairs(state.panel.id_by_line) do
    if id.node and id.node.relpath == relpath and id.section == 'unstaged' then return id.node end
  end
  error('unstaged 节点不存在: ' .. relpath)
end

---@param relpath string
local function show(relpath)
  RightView.show(state, unstaged_node(relpath), 'unstaged', false, state.git_root)
  assert(vim.wait(3000, function()
    return state.view and state.view.path == relpath and state.view._show_req_id == state._show_req_id
  end, 10), relpath .. ' 预览未挂载为当前 view')
end

-- 等首轮 open 的异步收尾（首次 BufEnter 触发的 debounce 等）全部落地，再开始计数
vim.wait(400)

local passive_reloads = 0
local reload_index = Loader.reload_index
Loader.reload_index = function(s, hint, passive)
  if passive then passive_reloads = passive_reloads + 1 end
  return reload_index(s, hint, passive)
end

test('双栏切到单栏后新 view 仍是当前 show，未被 WinClosed 拆掉', function()
  show('a.txt')
  assert(state.view.mode == 'diff2', '修改文件应走双栏，实际 ' .. tostring(state.view.mode))

  show('new.txt')
  assert(state.view.mode == 'single', '未跟踪文件应走单栏，实际 ' .. tostring(state.view.mode))
  vim.wait(50)
  assert(RightView.is_attached_current(state), '单栏 view 被标记为过期，被动 reshow 会失效')
end)

test('预览未加载的工作区文件不触发被动 reload_index', function()
  assert(vim.fn.bufloaded(repo .. '/b.txt') == 0, '前置条件：b.txt 尚未加载')
  -- 上一项首次建双栏时会进入主窗原 buffer，属于打开阶段的合法刷新；等它的 debounce 落地
  vim.wait(400)
  passive_reloads = 0

  show('b.txt')
  -- auto_refresh 的 debounce 是 200ms，等过它再判定
  vim.wait(400)
  assert(passive_reloads == 0, '预览触发了 ' .. passive_reloads .. ' 次被动 reload_index')
end)

Loader.reload_index = reload_index
pcall(Plugin.close)
vim.fn.delete(repo, 'rf')

print(string.format('\n%d passed, %d failed', passed, failed))
if failed > 0 then vim.cmd('cquit 1') end
vim.cmd('qa!')
