-- FileCompare 所有 Neovim 资源的幂等清理 helper
local M = {}

---@param id integer
---@return boolean deleted
function M.delete_autocmd(id)
  for _ = 1, 2 do
    pcall(vim.api.nvim_del_autocmd, id)
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { id = id })
    if ok and #autocmds == 0 then return true end
  end
  return false
end

---@param ids integer[]
---@param attempts integer
function M.retry_delete_autocmds(ids, attempts)
  if #ids == 0 or attempts <= 0 then return end
  vim.schedule(function()
    local remaining = {}
    for _, id in ipairs(ids) do
      if not M.delete_autocmd(id) then remaining[#remaining + 1] = id end
    end
    M.retry_delete_autocmds(remaining, attempts - 1)
  end)
end

---@param buf integer
---@param attempts integer
function M.retry_delete_buffer(buf, attempts)
  if attempts <= 0 or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    M.retry_delete_buffer(buf, attempts - 1)
  end)
end

return M
