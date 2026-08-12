-- X 执行入口时消费 vv-utils.exec 计划 cwd 的回归

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Commands = require('vv-git.core.commands')
local Keymaps = require('vv-git.core.keymaps')
local State = require('vv-git.state')

local original_exec = package.loaded['vv-utils.exec']
local original_cursor = Keymaps.id_under_cursor
local original_jobstart = vim.fn.jobstart

local project_root = vim.fn.tempname()
local entry_path = project_root .. '/src/main.rs'
vim.fn.mkdir(project_root .. '/src', 'p')

local plans = {
  { cmd = { 'cargo', 'run' }, cwd = project_root },
  { cmd = { 'custom-run', entry_path } },
  { cmd = { 'cargo', 'run' }, cwd = project_root },
  { cmd = { 'cargo', 'run' }, cwd = project_root },
  { cmd = { 'cargo', 'run' }, cwd = project_root },
  { cmd = { 'cargo', 'run' }, cwd = project_root },
}
local resolve_calls = {}
local jobs = {}
local confirms = {}
local next_plan = 1
local selected_root = project_root
package.loaded['vv-utils.exec'] = {
  resolve = function(path)
    resolve_calls[#resolve_calls + 1] = path
    local plan = plans[next_plan] or plans[#plans]
    next_plan = next_plan + 1
    return plan
  end,
  confirm = {
    open = function(opts)
      confirms[#confirms + 1] = opts
      return { close = function() end }
    end,
  },
}
Keymaps.id_under_cursor = function()
  return {
    root = selected_root,
    node = { relpath = 'src/main.rs', is_dir = false },
  }
end
vim.fn.jobstart = function(cmd, opts)
  jobs[#jobs + 1] = { cmd = cmd, cwd = opts.cwd }
  return 1
end

State.clear()
local state = State.create()
state.git_root = project_root
local commands = Commands.new({ controller = {}, config = function() return { binary = {} } end })

commands._execute()
assert(resolve_calls[1] == entry_path, 'execute 应解析选中的绝对路径')
confirms[1].on_confirm()
assert(vim.deep_equal(jobs[1].cmd, { 'cargo', 'run' }), 'execute 应原样透传解析后的 argv')
assert(jobs[1].cwd == project_root, 'execute 应优先使用 plan 项目目录作为 cwd')

commands._execute()
confirms[2].on_confirm()
assert(jobs[2].cwd == project_root .. '/src', 'execute 在缺省时应回退到 entry 文件目录')

local confirms_before_stale_root = #confirms
local resolves_before_stale_root = #resolve_calls
State.set_root(state, project_root .. '-other')
commands._execute()
assert(#confirms == confirms_before_stale_root, '旧 root 条目不应打开 execute 确认')
assert(#resolve_calls == resolves_before_stale_root, '旧 root 条目应在解析命令前被拒绝')
State.set_root(state, project_root)

commands._execute()
local jobs_before_stale = #jobs
state._closing = true
confirms[3].on_confirm()
assert(#jobs == jobs_before_stale, '关闭面板应取消待确认的 execute')
state._closing = nil

commands._execute()
jobs_before_stale = #jobs
State.set_root(state, project_root .. '-other')
confirms[4].on_confirm()
assert(#jobs == jobs_before_stale, '切换 root 应取消待确认的 execute')
State.set_root(state, project_root)

commands._execute()
jobs_before_stale = #jobs
State.set_root(state, project_root .. '-other')
State.set_root(state, project_root)
confirms[5].on_confirm()
assert(#jobs == jobs_before_stale, 'A 到 B 再到 A 时应取消旧的 execute 确认')

commands._execute()
commands._execute()
jobs_before_stale = #jobs
confirms[6].on_confirm()
assert(#jobs == jobs_before_stale, '被替代的 execute 确认不能启动任务')
confirms[7].on_confirm()
assert(#jobs == jobs_before_stale + 1, '最新的 execute 确认仍应可用')

-- 已打开确认框后子仓库从 state.subrepos 消失，不能启动旧命令。
local nested_root = project_root .. '/nested'
state.subrepos = { { root = nested_root } }
selected_root = nested_root
commands._execute()
local jobs_before_missing_subrepo = #jobs
state.subrepos = {}
confirms[#confirms].on_confirm()
assert(#jobs == jobs_before_missing_subrepo,
  '子仓库从 state.subrepos 消失后不能启动旧 execute')
selected_root = project_root

Keymaps.id_under_cursor = original_cursor
vim.fn.jobstart = original_jobstart
package.loaded['vv-utils.exec'] = original_exec
State.clear()
vim.fn.delete(project_root, 'rf')
print('PASS: vv-git execute cwd 回归')
