-- revision 自定义映射的边界回归：
-- 1. scratch diff buffer 能拿到对应 source path 与触发窗口
-- 2. worktree buffer 不安装该映射，避免覆盖并在清理时删除 LspAttach 映射

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local RightKeymaps = require('vv-git.right.keymaps')

local received
local keymaps = RightKeymaps.new({
  callbacks = {
    close = function() end,
    goto_file = function() end,
    yank_abs_path = function() end,
    toggle_stage = function() end,
    next_file = function() end,
    prev_file = function() end,
  },
  next_file_key = false,
  prev_file_key = false,
  revision_mappings = {
    K = function(context) received = context end,
  },
})

local function mapping(buf, lhs)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if item.lhs == lhs then return item.callback end
  end
end

local scratch = vim.api.nvim_create_buf(false, true)
vim.b[scratch].vv_git_scratch = true
vim.b[scratch].vv_git_source_path = '/tmp/project/main.lua'
vim.api.nvim_win_set_buf(0, scratch)
keymaps.install(scratch)

assert(mapping(scratch, 'K'), 'revision scratch 应安装自定义 K')()
assert(received and received.bufnr == scratch, '映射 context 应指向当前 scratch buffer')
assert(received.winid == vim.api.nvim_get_current_win(), '映射 context 应保留触发窗口')
assert(received.source_path == '/tmp/project/main.lua', '映射 context 应提供 worktree source path')

keymaps.remove(scratch)
assert(not mapping(scratch, 'K'), '清理 right keymaps 后应移除 revision 自定义映射')

local worktree = vim.api.nvim_create_buf(false, true)
vim.keymap.set('n', 'K', function() end, { buffer = worktree, desc = 'existing LSP hover' })
local before = assert(mapping(worktree, 'K'), '测试前提：worktree 已有 buffer-local K')
keymaps.install(worktree)
assert(mapping(worktree, 'K') == before, 'worktree 不应被 revision 自定义映射覆盖')
keymaps.remove(worktree)
assert(mapping(worktree, 'K') == before, '清理 vv-git 映射后应保留 worktree 原有 K')
