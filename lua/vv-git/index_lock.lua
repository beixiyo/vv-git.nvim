-- Git index lock 预检：只检查真实 index 路径，绝不自动删除锁文件

local M = {}

local STALE_SECONDS = 60

---@param value string?
---@param fallback string
---@return string
local function non_empty(value, fallback)
  value = vim.trim(value or '')
  return value ~= '' and value or fallback
end

---@param value string?
---@return string
local function strip_trailing_newlines(value)
  return (value or ''):gsub('[\r\n]+$', '')
end

---@param err any
---@return boolean
local function is_enoent(err, name)
  return name == 'ENOENT' or tostring(err or ''):match('^([A-Z]+)') == 'ENOENT'
end

---@param root string
---@param callback fun(path:string?, err?:string)
local function resolve_index_path(root, callback)
  local absolute_root = vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))

  local function finish(result, allow_fallback)
    if result.code == 0 then
      local path = strip_trailing_newlines(result.stdout)
      if path ~= '' then
        if vim.fn.isabsolutepath(path) == 1 then
          callback(vim.fs.normalize(path))
        else
          callback(vim.fs.normalize(absolute_root .. '/' .. path))
        end
        return
      end
    end

    if allow_fallback then
      vim.system(
        { 'git', '-C', root, 'rev-parse', '--git-path', 'index' },
        { text = true },
        vim.schedule_wrap(function(fallback)
          finish(fallback, false)
        end)
      )
      return
    end

    callback(nil, non_empty(result.stderr, 'could not resolve Git index path'))
  end

  vim.system(
    { 'git', '-C', root, 'rev-parse', '--path-format=absolute', '--git-path', 'index' },
    { text = true },
    vim.schedule_wrap(function(result)
      finish(result, true)
    end)
  )
end

M.resolve_path = resolve_index_path

---@param root string
---@param callback fun(ok:boolean, err?:string)
function M.ensure_available(root, callback)
  resolve_index_path(root, function(index, err)
    if not index then
      callback(false, non_empty(err, 'could not resolve Git index path'))
      return
    end

    local lock = index .. '.lock'
    local stat, stat_err, stat_name = vim.uv.fs_lstat(lock)
    if not stat then
      if is_enoent(stat_err, stat_name) then
        callback(true, nil, index)
      else
        callback(false, non_empty(stat_err, 'Could not inspect Git index lock: ' .. lock))
      end
      return
    end

    local age = os.time() - stat.mtime.sec
    if stat.size == 0 and age >= STALE_SECONDS then
      callback(false, 'Git index lock is stale and empty; remove it manually: ' .. lock)
      return
    end
    callback(false, 'Git index is locked: ' .. lock)
  end)
end

return M
