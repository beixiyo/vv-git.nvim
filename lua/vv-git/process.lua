-- vv-git 子进程生命周期：精确取消 active producer，并压制 queued delivery

local M = {}

---@param command string[]
---@param opts table
---@param callback fun(result: vim.SystemCompleted)
---@return fun() cancel
---@return any? start_error
function M.start(command, opts, callback)
  local cancelled = false
  local completed = false
  local process

  local function cancel()
    if cancelled then return end
    cancelled = true
    if not completed and process then pcall(process.kill, process, 'sigterm') end
  end

  local ok, result = pcall(vim.system, command, opts, function(value)
    completed = true
    vim.schedule(function()
      if not cancelled then callback(value) end
    end)
  end)

  if not ok then return cancel, result end
  process = result
  return cancel
end

---@param command string[]
---@param cb fun(ok:boolean, output?:string)
---@return fun() cancel
function M.network(command, cb)
  local cancelled = false
  local cancel_process, start_error = M.start(command, { text = true }, function(result)
    local out = (result.stdout or '') .. (result.stderr or '')
    cb(result.code == 0, out ~= '' and out or nil)
  end)
  if start_error then
    vim.schedule(function()
      if not cancelled then cb(false, tostring(start_error)) end
    end)
  end
  return function()
    if cancelled then return end
    cancelled = true
    cancel_process()
  end
end

return M
