-- Git 仓库元信息、remote 与 publish 操作

local Process = require('vv-git.process')
local M = {}

---@class VVGitRepoInfo
---@field branch? string
---@field branch_name? string
---@field head? string
---@field detached boolean
---@field unborn boolean
---@field remotes string[]
---@field upstream? string
---@field ahead integer
---@field behind integer

---@param status_output string
---@param remote_output string
---@return VVGitRepoInfo? info, string? err
function M._parse_repo_info(status_output, remote_output)
  local oid = status_output:match('# branch%.oid ([^\r\n]+)')
  local head = status_output:match('# branch%.head ([^\r\n]+)')
  if not oid or not head then return nil, 'git status did not report branch metadata' end

  local unborn = oid == '(initial)'
  local detached = head == '(detached)'
  local ahead, behind = status_output:match('# branch%.ab %+(%d+) %-(%d+)')
  local remotes = {}

  for remote in remote_output:gmatch('[^\r\n]+') do
    remote = vim.trim(remote)
    if remote ~= '' then remotes[#remotes + 1] = remote end
  end
  table.sort(remotes)

  return {
    branch = detached and (not unborn and oid:sub(1, 7) or nil) or head,
    branch_name = not detached and head or nil,
    head = not unborn and oid or nil,
    detached = detached,
    unborn = unborn,
    remotes = remotes,
    upstream = status_output:match('# branch%.upstream ([^\r\n]+)'),
    ahead = tonumber(ahead) or 0,
    behind = tonumber(behind) or 0,
  }
end

---@param root string
---@param cb fun(info: VVGitRepoInfo?, err?: string)
---@return fun() cancel
function M.repo_info(root, cb)
  local status_result, remote_result
  local producer_cancels = {}
  local cancelled = false
  local completed = false
  local failed = false

  local function cancel()
    if cancelled or completed then return end
    cancelled = true
    for _, cancel_producer in ipairs(producer_cancels) do pcall(cancel_producer) end
    producer_cancels = {}
  end

  local function finish()
    if cancelled or not status_result or not remote_result then return end
    if status_result.code ~= 0 then
      completed = true
      producer_cancels = {}
      cb(nil, status_result.stderr or 'git status failed')
      return
    end
    if remote_result.code ~= 0 then
      completed = true
      producer_cancels = {}
      cb(nil, remote_result.stderr or 'git remote failed')
      return
    end

    local info, err = M._parse_repo_info(status_result.stdout or '', remote_result.stdout or '')
    completed = true
    producer_cancels = {}
    cb(info, err)
  end

  local function start(args, deliver)
    local cancel_producer, start_error = Process.start(args, { text = true }, function(result)
      if cancelled or failed then return end
      deliver(result)
      finish()
    end)
    producer_cancels[#producer_cancels + 1] = cancel_producer
    if start_error then error(start_error) end
  end

  local ok, err = xpcall(function()
    start({ 'git', '-C', root, 'status', '--porcelain=v2', '--branch' }, function(result)
      status_result = result
    end)
    start({ 'git', '-C', root, 'remote' }, function(result)
      remote_result = result
    end)
  end, debug.traceback)

  if not ok then
    failed = true
    for _, cancel_producer in ipairs(producer_cancels) do pcall(cancel_producer) end
    producer_cancels = {}
    vim.schedule(function()
      if cancelled or completed then return end
      completed = true
      cb(nil, err)
    end)
  end

  return cancel
end

---@param root string
---@param name string
---@param url string
---@param cb fun(ok:boolean, output?:string)
---@return fun() cancel
function M.add_remote(root, name, url, cb)
  return Process.network({ 'git', '-C', root, 'remote', 'add', name, url }, cb)
end

---@param root string
---@param remote string
---@param cb fun(ok:boolean, output?:string)
---@return fun() cancel
function M.publish(root, remote, cb)
  return Process.network({ 'git', '-C', root, 'push', '-u', remote, 'HEAD' }, cb)
end

return M
