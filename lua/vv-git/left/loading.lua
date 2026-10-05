-- 左栏 loading 落点：远端动作提示行的文字开头 / 仓库标题行的折叠箭头槽
--
-- 行定位每帧从 state.panel.id_by_line 重新查找（render 时由 builder 写入），
-- render 重排后帧自动跟随；提示行消失时远端动作退回标题行，仓库不在面板里时隐藏
-- 停止由调用方挂在请求终结（disposer）上，panel buffer 被 wipe 时由 vv-utils.loading 自动停止

local Loading = require('vv-utils.loading')
local State = require('vv-git.state')
local Builder = require('vv-git.left.render.builder')

local M = {}

---@param state table
---@return integer? buf
local function panel_buf(state)
  if not State.is_current(state) or state._closing or not state.panel then return nil end
  local buf = state.panel.buf
  return buf and vim.api.nvim_buf_is_valid(buf) and buf or nil
end

---@param state table
---@param match fun(id: table): boolean
---@return integer? lnum 1-based
local function find_line(state, match)
  if not panel_buf(state) then return nil end
  for lnum, id in pairs(state.panel.id_by_line or {}) do
    if match(id) then return lnum end
  end
end

-- 标题行第 0 列 overlay，宽度补齐到箭头槽，不挤动分支名
---@param state table
---@param buf integer
---@param get_root fun(): string?
---@return vv-utils.loading.Handle
local function header_mark(state, buf, get_root)
  return Loading.mark({
    buf = buf,
    pos = 'overlay',
    width = Builder.ARROW_COLS,
    get_pos = function()
      local root = get_root()
      local lnum = root and find_line(state, function(id) return id.block_header == root end)
      return lnum and { row = lnum, col = 0 }
    end,
  })
end

--- push / pull / publish 的 loading：提示行在时帧插在文字开头（`p  ⠋ Push 3 commits`），
--- 否则盖住该仓库标题行的折叠箭头
---@param state table
---@param root string
---@param action 'push'|'pull'|'publish'
---@return fun() stop 幂等
function M.remote_action(state, root, action)
  local buf = panel_buf(state)
  if not buf then return function() end end

  local function hint_line()
    return find_line(state, function(id) return id.root == root and id.action == action end)
  end

  local hint = Loading.mark({
    buf = buf,
    prefix = '',
    suffix = ' ',
    get_pos = function()
      local lnum = hint_line()
      if not lnum then return nil end
      local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ''
      -- `<indent><key>  <text>`：落在 key 后两个空格之后
      local lead = line:match('^%s*%S+%s%s')
      return { row = lnum, col = lead and #lead or 0 }
    end,
  })
  local header = header_mark(state, buf, function()
    if hint_line() then return nil end
    return root
  end)

  return function()
    hint:stop()
    header:stop()
  end
end

---@param pending table<table, vv-git.IndexWrite>
---@param id table id_by_line 条目
---@return integer? col 命中时的帧起始列
local function index_write_col(pending, id)
  for write in pairs(pending) do
    for _, item in ipairs(write.items) do
      if id.root == item.root and id.base == item.base then
        if item.relpath == nil and id.section_header then return id.arrow_col end
        if item.relpath ~= nil and id.node and id.node.relpath == item.relpath then return id.icon_col end
      end
    end
  end
end

--- stage / unstage / discard 在途标记：帧盖在被操作项的图标槽（文件 / 目录）或折叠箭头（分组标题）上
---
--- 帧持续到「写入完成之后才开始」的那次 reload 成功渲染为止——写入完成时文件还在旧分组，
--- 要等 reload 把它移到另一分组才算完成；写入失败立即撤掉。同一 state 的全部在途写入共用一个
--- mark，快速连按时多行同步转动
---@param state table
---@param items { root: string, base: string, relpath?: string }[] relpath 为 nil 表示整个分组
---@return fun(ok: boolean) written 写入结束时调用一次（幂等）；成功后帧保留到随后的 reload 渲染完成
function M.begin_write(state, items)
  local buf = panel_buf(state)
  if not buf or #items == 0 then return function() end end

  local pending = state._index_writes
  if not pending then
    pending = {}
    state._index_writes = pending
  end
  ---@type vv-git.IndexWrite
  local write = { items = items }
  pending[write] = true

  local mark = state._index_write_mark
  if not mark or not mark:is_active() then
    state._index_write_mark = Loading.mark({
      buf = buf,
      pos = 'overlay',
      width = Builder.ARROW_COLS,
      delay_ms = 150,
      get_pos = function()
        if not panel_buf(state) then return nil end
        local positions = {}
        for lnum, id in pairs(state.panel.id_by_line or {}) do
          local col = index_write_col(pending, id)
          if col then positions[#positions + 1] = { row = lnum, col = col } end
        end
        return positions
      end,
    })
  end

  local settled = false
  return function(ok)
    if settled then return end
    settled = true
    if ok then
      -- 序号大于它的 reload 才是写入完成后发起的，渲染结果反映新状态
      write.after_seq = state._reload_seq or 0
    else
      pending[write] = nil
      M._stop_index_write_mark_if_idle(state)
    end
  end
end

--- loader 在 reload 成功完成（含结果未变跳过渲染）时调用：清掉在该 reload 发起前已写入完成的标记
---@param state table
---@param seq integer 该 reload 发起时的序号
function M.reload_settled(state, seq)
  local pending = state._index_writes
  if not pending then return end
  for write in pairs(pending) do
    if write.after_seq and seq > write.after_seq then pending[write] = nil end
  end
  M._stop_index_write_mark_if_idle(state)
end

---@param state table
function M._stop_index_write_mark_if_idle(state)
  if next(state._index_writes or {}) then return end
  if state._index_write_mark then state._index_write_mark:stop() end
  state._index_write_mark = nil
end

--- 手动刷新的 loading：同一 state 的多次刷新共用一个 slot（盖住根仓库标题行箭头）
--- 返回本次登记的幂等 release，必须挂在 reload 请求终结上（被顶掉的请求不会调用 after）
---@param state table
---@return fun() release
function M.acquire_refresh(state)
  local buf = panel_buf(state)
  if not buf then return function() end end

  if not state._refresh_loading then
    state._refresh_loading = Loading.slot(function()
      return header_mark(state, buf, function() return state.git_root end)
    end)
  end
  return state._refresh_loading:acquire()
end

return M

---@class vv-git.IndexWrite
---@field items { root: string, base: string, relpath?: string }[]
---@field after_seq? integer 写入成功时的 reload 序号；nil 表示写入尚未完成
