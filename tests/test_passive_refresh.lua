-- 回归：passive 刷新（auto_refresh / 保存 / gitsigns / R / commit）不拉扯光标
-- render(state, true) 保持光标停在当前文件、不按滞后 cur_path 拉走；非 passive 仍走 cur_path
-- 用法: cd vv-git.nvim && nvim --headless -u NONE -l tests/test_passive_refresh.lua
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
local vendors_root = vim.fn.fnamemodify(plugin_root, ':h')

local paths = { plugin_root .. '/lua/?.lua', plugin_root .. '/lua/?/init.lua' }
for _, dir in ipairs(vim.fn.glob(vendors_root .. '/vv-*.nvim', false, true)) do
  paths[#paths + 1] = dir .. '/lua/?.lua'
  paths[#paths + 1] = dir .. '/lua/?/init.lua'
end
paths[#paths + 1] = package.path
package.path = table.concat(paths, ';')

local State = require('vv-git.state')
local Tree = require('vv-git.tree')
local Render = require('vv-git.left.render')
local Panel = require('vv-git.left.panel')

local pass, fail = 0, 0
local function check(c, l) if c then pass = pass + 1; print('PASS: ' .. l) else fail = fail + 1; print('FAIL: ' .. l) end end

local ROOT = '/tmp/vvfake'
local function smap(extra)
  local m = { [ROOT .. '/a.txt'] = ' M', [ROOT .. '/b.txt'] = ' M', [ROOT .. '/c.txt'] = ' M' }
  if extra then m[ROOT .. '/' .. extra] = ' M' end
  return m
end

local buf = Panel.create_buf()
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)

local state = State.create()
state.git_root = ROOT
state.panel = { buf = buf, win = win, main_win = win }
state.folds, state.section_folds, state.selection = {}, {}, {}

local function line_of(relpath)
  for lnum, id in pairs(state.panel.id_by_line) do
    if id.node and id.node.relpath == relpath and id.section == 'unstaged' then return lnum end
  end
end

-- 初始渲染
state.tree = Tree.build(smap(), ROOT)
state.cur_path, state.cur_section = 'a.txt', 'unstaged'
Render.render(state)
local lb = line_of('b.txt')
check(lb, 'b.txt 渲染出行号')

-- Test A：passive 刷新（cur_path 滞后在 a.txt）——光标在 b.txt，应保持在 b.txt
vim.api.nvim_win_set_cursor(win, { lb, 0 })
state.cur_path, state.cur_section = 'a.txt', 'unstaged'  -- 故意滞后
state._action_hint, state._section_hint = nil, nil
Render.render(state, true)  -- passive
check(vim.api.nvim_win_get_cursor(win)[1] == lb, '场景A：passive 刷新时光标留在 b.txt，不会被拉回 a.txt')

-- Test B：passive 刷新且内容变化（README 冒出来，排序在 b 之前）——光标跟随 b.txt 到新行
vim.api.nvim_win_set_cursor(win, { lb, 0 })
state.cur_path, state.cur_section = 'a.txt', 'unstaged'  -- 仍滞后
state.tree = Tree.build(smap('aa_new.txt'), ROOT)  -- 新文件 aa_new 排在 a 之后、b 之前 → b 整体下移
Render.render(state, true)  -- passive
local lb2 = line_of('b.txt')
check(vim.api.nvim_win_get_cursor(win)[1] == lb2, '场景B：内容变化后 passive 刷新，光标跟随 b.txt 到新行 ' .. tostring(lb2))

-- Test C：非 passive 渲染仍按 cur_path 定位（普通行为不变）
state.tree = Tree.build(smap(), ROOT)
vim.api.nvim_win_set_cursor(win, { line_of('c.txt') or 1, 0 })
state.cur_path, state.cur_section = 'a.txt', 'unstaged'
Render.render(state)  -- 非 passive
check(vim.api.nvim_win_get_cursor(win)[1] == line_of('a.txt'), '场景C：非 passive 渲染仍落到 cur_path=a.txt')

-- Test D：passive 但带 _action_hint（动作渲染）——不进 passive 分支，走 _action_hint 落点
state.tree = Tree.build(smap(), ROOT)
Render.render(state)
local lc = line_of('c.txt')
vim.api.nvim_win_set_cursor(win, { line_of('a.txt'), 0 })
state.cur_path, state.cur_section = 'c.txt', 'unstaged'
state._action_hint = { section = 'unstaged', lnum = line_of('a.txt'), next_path = 'c.txt', prev_path = nil }
Render.render(state, true)  -- passive=true 但有 _action_hint，应让 _action_hint 优先
check(vim.api.nvim_win_get_cursor(win)[1] == lc, '场景D：_action_hint 生效时忽略 passive，落到 next_path=c.txt')

-- Test E：fold_staged 默认折叠时，从 staged-only 文件打开应展开 staged 并聚焦该文件
state.tree = Tree.build({
  [ROOT .. '/staged-only.txt'] = 'M ',
  [ROOT .. '/other-change.txt'] = ' M',
}, ROOT)
state.folds = {}
state.section_folds = { staged = true }
state._fold_staged_pending = true
state.cur_path, state.cur_section = 'staged-only.txt', nil
Render.render(state)
local staged_target
for lnum, id in pairs(state.panel.id_by_line) do
  if id.node and id.node.relpath == 'staged-only.txt' and id.section == 'staged' then
    staged_target = lnum
    break
  end
end
check(staged_target ~= nil, '场景E：当前 staged-only 文件所在 section 被展开')
check(vim.api.nvim_win_get_cursor(win)[1] == staged_target, '场景E：光标落到 staged-only 文件行')

-- Test F：同一文件既 staged 又有工作区变更时，staged 保持折叠，光标落到 Changes
state.tree = Tree.build({
  [ROOT .. '/both-sides.txt'] = 'MM',
}, ROOT)
state.folds = {}
state.section_folds = { staged = true }
state._fold_staged_pending = true
state.cur_path, state.cur_section = 'both-sides.txt', nil
Render.render(state)
local staged_both, unstaged_both
for lnum, id in pairs(state.panel.id_by_line) do
  if id.node and id.node.relpath == 'both-sides.txt' then
    if id.section == 'staged' then staged_both = lnum end
    if id.section == 'unstaged' then unstaged_both = lnum end
  end
end
check(staged_both == nil, '场景F：staged+unstaged 当前文件不展开 staged section')
check(unstaged_both ~= nil, '场景F：staged+unstaged 当前文件显示在 Changes')
check(vim.api.nvim_win_get_cursor(win)[1] == unstaged_both, '场景F：光标落到工作区 Changes 文件行')

-- Test G：仅 staged changes 时初次自动展开，但之后的手动折叠必须保留
state.tree = Tree.build({
  [ROOT .. '/only-staged.txt'] = 'M ',
}, ROOT)
state.folds = {}
state.section_folds = { staged = true }
state._fold_staged_pending = true
state.cur_path, state.cur_section = 'only-staged.txt', nil
Render.render(state)

local function staged_line_of(relpath)
  for lnum, id in pairs(state.panel.id_by_line) do
    if id.node and id.node.relpath == relpath and id.section == 'staged' then return lnum end
  end
end

check(staged_line_of('only-staged.txt') ~= nil, '场景G：仅 staged changes 时初次自动展开')
check(state.section_folds.staged == nil, '场景G：自动展开会同步真实 fold state')

state.section_folds.staged = true
Render.render(state)
check(staged_line_of('only-staged.txt') == nil, '场景G：后续手动折叠不受自动展开抵消')
check(state.section_folds.staged == true, '场景G：手动折叠状态保持一致')

print(string.format('\n总计: %d 通过, %d 失败', pass, fail))
if fail > 0 then vim.cmd('cq') end
