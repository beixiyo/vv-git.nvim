-- 左栏窗口管理：vsplit 创建 / 关闭 / buffer 生命周期
-- 参考 vv-explorer/window.lua：buffer 用 bufhidden='hide' 跨 close/open 保留内容

local ui_window = require('vv-utils.ui_window')

local M = {}

M.FILETYPE = 'vv-git-panel'

---@return integer buf
function M.create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = M.FILETYPE
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, 'vv-git://panel/' .. tostring(buf))
  return buf
end

---@param win integer
local function apply_win_opts(win)
  ui_window.hide_chrome(win, {
    cursorline = true,
    winfixwidth = true,
    winfixbuf = true,
  })
  -- 显式从 diff-group 摘出。未显式设过的 win-local 选项处于"default 态"，
  -- 在 VimResized / panel 重建 / 第三方浮窗创建等路径上可能被继承/污染进 diff-group。
  -- 写死 false 让本 panel 永不进 diff 计算，新浮窗从 panel 继承也拿不到污染状态。
  -- 对照 diffview panel.lua:50-52 同样做法
  vim.wo[win].diff = false
  vim.wo[win].scrollbind = false
  vim.wo[win].cursorbind = false
end

---@param buf integer
---@param opts {width:integer}
---@return integer win, integer prev_win
function M.open_split(buf, opts)
  local prev = vim.api.nvim_get_current_win()
  vim.cmd('topleft vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, opts.width)
  vim.api.nvim_win_set_buf(win, buf)
  apply_win_opts(win)
  return win, prev
end

---@param win integer
function M.close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---@param buf integer
function M.wipe_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---@param buf integer
---@param lines string[]
---@param extmarks table[]  { row, col, opts }
---@param ns integer
function M.flush(buf, lines, extmarks, ns)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, em in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, em.row, em.col, em.opts)
  end
  vim.bo[buf].modifiable = false
end

return M
