-- diff buffer 生命周期：revision scratch、worktree buffer、高亮 attach 与安全清理

local api = vim.api
local Git = require('vv-git.git')

local M = {}

local SCRATCH_FILETYPE = 'vv-git-a'

-- 创建某个 revision 的只读 scratch buffer
---@param root string
---@param rev string
---@param relpath string
---@param callback fun(buf:integer?, err?:string)
function M.create_revision(root, rev, relpath, callback)
  Git.show(root, rev, relpath, function(lines, err)
    if not lines then callback(nil, err); return end

    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_option_value('buftype', 'nowrite', { buf = buf })
    api.nvim_set_option_value('swapfile', false, { buf = buf })
    api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_set_option_value('modifiable', false, { buf = buf })

    -- 不设置 buffer name：同一文件两侧会发生名称抢占。直接用 relpath 匹配 filetype。
    local ft = vim.filetype.match({ filename = relpath, buf = buf }) or SCRATCH_FILETYPE
    api.nvim_set_option_value('filetype', ft, { buf = buf })
    -- 用户的 FileType autocmd 可能跳过 buftype ~= '' 的特殊 buffer，因此 scratch
    -- 必须主动 attach Treesitter；bigfile/minified 内容主动启动解析会阻塞 diff 切换。
    if ft ~= 'bigfile' then pcall(vim.treesitter.start, buf) end

    -- 只有此标记存在时 wipe_scratch 才允许删除，避免误删第三方设置为 wipe 的工作区 buffer。
    vim.b[buf].vv_git_scratch = true
    vim.b[buf].vv_git_source_path = vim.fs.normalize(root .. '/' .. relpath)
    callback(buf)
  end)
end

-- 获取或加载工作区文件的真实 buffer；bufadd 提供 exact-match 且幂等的复用语义
---@param abspath string
---@return integer
function M.get_worktree(abspath)
  local buf = vim.fn.bufadd(abspath)
  if not api.nvim_buf_is_loaded(buf) then vim.fn.bufload(buf) end
  return buf
end

-- 为已存在的 buffer 补齐 filetype 与 treesitter；重复调用安全。worktree buffer 通常
-- 依赖 bufload 触发 FileType 链，但它在 schedule callback 内执行时不保证 autocmd 链
-- 已完整结束，所以 attach 后仍需统一兜底，不能把它当成 create_revision 的重复逻辑。
---@param buf integer?
---@param relpath? string
function M.ensure_highlighting(buf, relpath)
  if not buf or not api.nvim_buf_is_valid(buf) then return end

  local ft = vim.bo[buf].filetype
  if ft == '' then
    local name = relpath or api.nvim_buf_get_name(buf)
    ft = vim.filetype.match({ filename = name, buf = buf }) or ''
    if ft ~= '' and ft ~= 'bigfile' then
      api.nvim_set_option_value('filetype', ft, { buf = buf })
    end
  end
  -- bigfile/minified 文件主动启动 Treesitter 会卡住文件切换，必须保持跳过。
  if ft ~= '' and ft ~= 'bigfile' then pcall(vim.treesitter.start, buf) end
end

-- 仅清理 vv-git 自建的 scratch，工作区 buffer 永不删除
---@param bufs integer[]?
function M.wipe_scratch(bufs)
  for _, buf in ipairs(bufs or {}) do
    if buf and api.nvim_buf_is_valid(buf) and vim.b[buf].vv_git_scratch then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
