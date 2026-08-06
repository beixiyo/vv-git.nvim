-- Git index 写入队列：同一仓库串行，不同仓库互不阻塞

local M = {}

local queues = {}

---@param root string
---@return table
local function queue_for(root)
  local queue = queues[root]
  if not queue then
    queue = { running = false, items = {} }
    queues[root] = queue
  end
  return queue
end

---@param root string
---@param queue table
local function pump(root, queue)
  if queue.running then return end

  local item = table.remove(queue.items, 1)
  if not item then
    queues[root] = nil
    return
  end

  queue.running = true
  local completed = false
  local function complete(ok, err)
    if completed then return end
    completed = true
    local idle = #queue.items == 0
    local callback_ok, callback_err = xpcall(function()
      item.callback(ok, err, idle)
    end, debug.traceback)
    queue.running = false
    pump(root, queue)
    if not callback_ok then
      vim.schedule(function() error(callback_err, 0) end)
    end
  end

  local start_ok, start_err = xpcall(function() item.start(complete) end, debug.traceback)
  if not start_ok then complete(false, start_err) end
end

---@param root string
---@param start fun(done:fun(ok:boolean, err?:string))
---@param callback fun(ok:boolean, err?:string, idle:boolean)
function M.enqueue(root, start, callback)
  local queue = queue_for(root)
  queue.items[#queue.items + 1] = { start = start, callback = callback }
  pump(root, queue)
end

---@param root string
---@return boolean
function M.is_active(root)
  return queues[root] ~= nil
end

return M
