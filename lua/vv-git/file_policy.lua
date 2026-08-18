-- 文件类型策略：把 vv-git 配置适配为 vv-utils 的内容探测接口

local FileProbe = require('vv-utils.fs.file_probe')
local M = {}

---@param path string
---@param config VVGitBinaryConfig?
---@return VVFsFileInfo?
function M.binary_info(path, config)
  if not config or not config.intercept then return nil end
  local info = FileProbe.inspect(path, { extensions = config.extensions })
  return info.binary and info or nil
end

---@param path string
---@param config VVGitBinaryConfig?
---@return boolean
function M.is_binary(path, config)
  return M.binary_info(path, config) ~= nil
end

return M
