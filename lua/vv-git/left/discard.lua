-- Discard confirmation and irreversible operation lifecycle

local Git = require('vv-git.git')
local State = require('vv-git.state')
local Async = require('vv-utils.async')
local Confirm = require('vv-utils.confirm')
local Subrepo = require('vv-git.subrepo')
local Fs = require('vv-utils.fs')

local M = {}
local scope = Async.scope({ cancel_previous = true })

---@param name string
---@param path string
---@return boolean
local function under(name, path)
  return name == path or name:sub(1, #path + 1) == path .. '/'
end

-- discard 在磁盘上还原或删除了文件，让已打开的 buffer 跟上，否则 LSP 会继续以旧内容、已不存在的路径为准：
--   - 文件被删掉（未跟踪文件；或还原后不存在）：关闭未修改的 buffer，服务端收到 didClose（Fs.close_stale_buffers）
--   - 文件被还原：对未修改的 buffer checktime，autoread 重新加载，服务端收到新内容（关掉 autoread 时跳过）
-- 已修改的 buffer 这里不关闭、不 checktime（关闭会丢失未保存内容）；Neovim 自己之后的时间戳检查仍可能对它弹 W12
---@param root string
---@param paths string[] 相对 root 的路径
local function sync_buffers(root, paths)
  for _, relpath in ipairs(paths) do
    local path = vim.fs.normalize(root .. '/' .. relpath)
    Fs.close_stale_buffers(path)

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and not vim.bo[buf].modified then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' and under(vim.fs.normalize(name), path) then
          -- 必须带 bufnr：不带参数的 checktime 检查全部 buffer，已修改且被还原的 buffer 照样会弹 W12。
          -- 关掉 autoread 时 checktime 会弹阻塞的 W11 提示，留给 Neovim 之后自己检查
          pcall(vim.api.nvim_buf_call, buf, function()
            if vim.o.autoread then vim.cmd('silent! checktime ' .. buf) end
          end)
        end
      end
    end
  end
end

---@param state table
---@param groups {root:string, tracked:string[], untracked:string[]}[]
---@param opts {title:string, message:any, severity:'warn'|'danger', after:fun(), on_cancel?:fun(), owner_root?:string, owner_generation?:integer}
function M.confirm(state, groups, opts)
  local owner_root = opts.owner_root or state.git_root
  local owner_generation = opts.owner_generation or State.root_generation(state)
  local request = scope:begin({ key = 'discard' })
  local handle

  local function groups_are_current()
    for _, group in ipairs(groups) do
      if Subrepo.current_root(state, group.root) ~= group.root then return false end
    end
    return true
  end

  local function current()
    local panel = state.panel
    return request:is_current()
        and State.is_current(state)
        and not state._closing
        and state.git_root == owner_root
        and State.root_generation(state) == owner_generation
        and groups_are_current()
        and (not panel or (panel.buf and vim.api.nvim_buf_is_valid(panel.buf)
          and panel.win and vim.api.nvim_win_is_valid(panel.win)))
  end

  local function dispose()
    state._action_hint = nil
    request:dispose()
  end

  handle = Confirm.open({
    title = opts.title,
    message = opts.message,
    severity = opts.severity,
    confirm_label = 'Discard',
    on_confirm = function()
      if not current() then dispose(); return end
      local operations = {}
      for _, group in ipairs(groups) do
        if #group.tracked > 0 then
          operations[#operations + 1] = { root = group.root, paths = group.tracked, apply = Git.discard }
        end
        if #group.untracked > 0 then
          operations[#operations + 1] = {
            root = group.root,
            paths = group.untracked,
            apply = Git.discard_untracked,
          }
        end
      end

      local function run(index, first_error)
        if not current() then dispose(); return end
        local operation = operations[index]
        if not operation then
          if first_error then
            vim.notify('[vv-git] discard failed: ' .. tostring(first_error), vim.log.levels.ERROR)
          end
          if request:finish() then opts.after() end
          return
        end
        operation.apply(operation.root, operation.paths, function(ok, err)
          -- 不论成败、也不论面板是否已过期都要同步：磁盘可能已经被部分改动。
          -- 同步出错（用户 autocmd 等）不能打断后续操作与面板刷新
          pcall(sync_buffers, operation.root, operation.paths)
          run(index + 1, first_error or (not ok and (err or 'operation failed')) or nil)
        end)
      end

      run(1)
    end,
    on_cancel = function()
      dispose()
      if opts.on_cancel then opts.on_cancel() end
    end,
  })

  if type(handle) == 'table' and type(handle.close) == 'function' then
    request:set_disposer(function()
      state._action_hint = nil
      handle.close()
    end)
  else
    request:dispose()
  end
end

function M.cancel()
  scope:cancel()
end

return M
