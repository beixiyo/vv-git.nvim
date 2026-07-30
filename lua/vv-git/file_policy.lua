-- 文件类型策略的纯判断；调用方负责决定跳过预览、系统打开或其它行为

local M = {}

---@param path string
---@param config VVGitBinaryConfig?
---@return boolean
function M.is_binary(path, config)
  if not config or not config.intercept then return false end
  local ext = path:match('%.([%w_]+)$')
  return ext and config.extensions[ext:lower()] or false
end

return M
