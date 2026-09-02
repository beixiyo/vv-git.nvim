-- Git 索引与基础操作：状态分类、index 写队列、stage/commit/discard

local utils_git = require('vv-utils.git')
local Fs = require('vv-utils.fs')
local Process = require('vv-git.process')
local IndexLock = require('vv-git.index_lock')
local IndexQueue = require('vv-git.index_queue')

local M = {}
local index_resolutions = {}

---@param root string
---@param cb fun(index: vv-utils.git.Index?)
---@return fun() cancel
function M.index(root, cb)
  return utils_git.index(root, cb, { untracked = 'all', ignored = false })
end

M.is_conflict = utils_git.is_conflict

---@param xy string
---@return boolean staged, boolean unstaged
function M.classify(xy)
  if xy == '??' then return false, true end
  if utils_git.is_conflict(xy) then return false, false end
  local x = xy:sub(1, 1)
  local y = xy:sub(2, 2)
  return x ~= ' ', y ~= ' '
end

local function run(root, args, cb)
  vim.system(
    vim.list_extend({ 'git', '-C', root }, args),
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(false, r.stderr or 'git failed') else cb(true) end
    end)
  )
end

---@param root string
---@param cb fun(ok:boolean, stderr?:string)
function M.init(root, cb)
  run(root, { 'init' }, cb)
end

local function with_index(root, action, cb, opts)
  IndexLock.ensure_available(root, function(ok, err)
    if not ok then cb(false, err); return end
    if opts and opts.is_current and not opts.is_current() then
      cb(false, 'Git operation cancelled: request is no longer current')
      return
    end
    local action_ok, action_err = xpcall(action, debug.traceback)
    if not action_ok then cb(false, action_err) end
  end)
end

local function queue_index_write(root, action, cb, opts)
  local canonical_root = vim.uv.fs_realpath(root)
      or vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))
  local resolution_key = canonical_root .. '\0' .. (vim.env.GIT_INDEX_FILE or '')
  local resolution = index_resolutions[resolution_key]

  if not resolution then
    resolution = { pending = {} }
    index_resolutions[resolution_key] = resolution
  end

  local function enqueue(index_path)
    local index_key = vim.uv.fs_realpath(index_path)
    if not index_key then
      local parent = vim.fs.dirname(index_path)
      local real_parent = vim.uv.fs_realpath(parent)
      index_key = real_parent and (real_parent .. '/' .. vim.fs.basename(index_path))
          or vim.fs.normalize(index_path)
    end
    resolution.index_key = index_key

    IndexQueue.enqueue(index_key, function(done)
      with_index(root, function() action(done) end, done, opts)
    end, function(ok, err, idle)
      local callback_ok, callback_err = xpcall(function() cb(ok, err, idle) end, debug.traceback)
      if idle then
        vim.schedule(function()
          if IndexQueue.is_active(index_key) then return end
          for key, candidate in pairs(index_resolutions) do
            if candidate.index_key == index_key then index_resolutions[key] = nil end
          end
        end)
      end
      if not callback_ok then error(callback_err, 0) end
    end)
  end

  if resolution.path then enqueue(resolution.path); return end
  resolution.pending[#resolution.pending + 1] = {
    enqueue = enqueue,
    reject = function(err) cb(false, err) end,
  }
  if resolution.resolving then return end
  resolution.resolving = true

  IndexLock.resolve_path(root, function(index_path, err)
    resolution.resolving = false
    local pending = resolution.pending
    resolution.pending = {}
    if not index_path then
      index_resolutions[resolution_key] = nil
      for _, item in ipairs(pending) do
        local ok, callback_err = xpcall(function() item.reject(err) end, debug.traceback)
        if not ok then vim.schedule(function() error(callback_err, 0) end) end
      end
      return
    end
    resolution.path = index_path
    for _, item in ipairs(pending) do item.enqueue(index_path) end
  end)
end

local function run_paths(root, prefix_args, paths, cb)
  if #paths == 0 then cb(true); return end
  local args = vim.list_extend(vim.deepcopy(prefix_args), paths)
  run(root, args, cb)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string, idle?:boolean)
---@param opts? VVGitIndexWriteOptions
function M.stage(root, paths, cb, opts)
  queue_index_write(root, function(done)
    run_paths(root, { 'add', '--' }, paths, done)
  end, cb, opts)
end

---@param root string
---@param cb fun(ok:boolean, stderr?:string)
---@param opts? VVGitIndexWriteOptions
function M.stage_all(root, cb, opts)
  queue_index_write(root, function(done) run(root, { 'add', '-A' }, done) end, cb, opts)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string, idle?:boolean)
---@param opts? VVGitIndexWriteOptions
function M.unstage(root, paths, cb, opts)
  if #paths == 0 then cb(true); return end
  queue_index_write(root, function(done)
    vim.system(
      { 'git', '-C', root, 'rev-parse', '--verify', 'HEAD' },
      { text = true },
      vim.schedule_wrap(function(r)
        if r.code == 0 then
          run_paths(root, { 'restore', '--staged', '--' }, paths, done)
        else
          run_paths(root, { 'rm', '--cached', '--' }, paths, done)
        end
      end)
    )
  end, cb, opts)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
function M.discard(root, paths, cb)
  run_paths(root, { 'restore', '--worktree', '--' }, paths, cb)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
function M.discard_untracked(root, paths, cb)
  local errors = {}
  for _, p in ipairs(paths) do
    local ok, err = pcall(Fs.delete, root .. '/' .. p)
    if not ok then errors[#errors + 1] = p .. ': ' .. tostring(err) end
  end
  if #errors > 0 then cb(false, table.concat(errors, '\n')) else cb(true) end
end

---@param root string
---@param message string
---@param cb fun(ok:boolean, stderr?:string)
---@param opts? VVGitIndexWriteOptions
function M.commit(root, message, cb, opts)
  queue_index_write(root, function(done)
    vim.system(
      { 'git', '-C', root, 'commit', '-F', '-' },
      { text = true, stdin = message },
      vim.schedule_wrap(function(r)
        if r.code ~= 0 then
          done(false, r.stderr or r.stdout or 'commit failed')
        else
          done(true, r.stdout)
        end
      end)
    )
  end, cb, opts)
end

local function net_op(root, sub, cb)
  return Process.network({ 'git', '-C', root, sub }, cb)
end

---@param root string
---@param cb fun(ok:boolean, output?:string)
---@return fun() cancel
function M.push(root, cb) return net_op(root, 'push', cb) end

---@param root string
---@param cb fun(ok:boolean, output?:string)
---@return fun() cancel
function M.pull(root, cb) return net_op(root, 'pull', cb) end

---@param root string
---@param cb fun(has_staged: boolean)
function M.has_staged(root, cb)
  vim.system(
    { 'git', '-C', root, 'diff', '--cached', '--quiet' },
    { text = true },
    vim.schedule_wrap(function(r) cb(r.code == 1) end)
  )
end

M._run = run
M._run_paths = run_paths
M._queue_index_write = queue_index_write

---@class VVGitIndexWriteOptions
---@field is_current? fun():boolean Request guard checked immediately before starting Git. @default nil

return M
