-- panel 预览与 diff 文件导航

local Timer = require('vv-utils.timer')

local L = {}

---@param context table
---@return table
function L.new(context)
  local M = {}
  local State = context.State
  local Keymaps = context.Keymaps
  local RightView = context.RightView
  local Navigation = context.Navigation
  local function config() return context.config() end
  local function narrow() return context.narrow() end

  M._reshow_view = State.guarded(function(state)
    local view = state.view
    if not view or not view.node then return end
    -- 新文件的异步 show 尚未 attach 时，state.view 仍指向旧 buffer。此时任何
    -- 被动 reshow 都不能拿旧 view 再发请求，否则会以更大的 req_id 覆盖新目标
    if not RightView.is_attached_current(state) then return end

    local node, section = view.node, view.section
    state.view.path = nil
    state._reshow_restore_win = vim.api.nvim_get_current_win()
    RightView.show(state, node, section, narrow(), view.root)
  end)

  M._preview = State.guarded(function(state)
    if not config().preview then return end
    if not state.panel or state.panel.win ~= vim.api.nvim_get_current_win() then return end

    local id = Keymaps.id_under_cursor(state)
    if not id or id.section_header then return end
    local node = id.node

    if not node then return end
    if node.is_dir and not config().directory_preview then return end

    local root = id.root or state.git_root
    local view = state.view

    if view and view.path == node.relpath and view.section == id.base and view.root == root
        and view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
      return
    end
    -- 目录只是变更树的聚合节点，预览它不改变「当前文件」，否则 stage / 导航
    -- 这些按文件工作的动作会拿着一个目录路径去执行
    if not node.is_dir then
      state.cur_path = node.relpath
      state.cur_section = id.section
    end

    RightView.show(state, node, id.base, narrow(), root)
  end)

  -- 预览防抖：单例常驻 timer，wait 每次读取最新 config
  local preview_debounced = Timer.debounce(function()
    M._preview()
  end, function() return config().preview_debounce_ms or 0 end)

  -- CursorMoved 入口：>0 走防抖（光标停顿后才刷新 diff），0 保持同步直刷
  M._preview_on_move = function()
    if (config().preview_debounce_ms or 0) > 0 then
      preview_debounced()
    else
      M._preview()
    end
  end

  -- 从右侧 buffer 切换左栏中的上/下一个文件。只移动 panel 光标，不把焦点
  -- 切到 panel；RightView 的 restore 机制会在异步 show 完成后回到触发窗口
  M._navigate_view_file = State.guarded(function(state, direction)
    local panel = state.panel
    if not panel or not panel.win or not vim.api.nvim_win_is_valid(panel.win) then return end

    local current = vim.api.nvim_win_get_cursor(panel.win)[1]
    local target = Navigation.move(panel.id_by_line, current, direction, function(id)
      local node = id and id.node
      local root = id and (id.root or state.git_root)
      return node and not node.is_dir and root
    end)
    if not target then return end

    local restore_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(panel.win, { target.lnum, 0 })
    state.cur_path = target.id.node.relpath
    state.cur_section = target.id.section
    state._reshow_restore_win = restore_win
    local root = target.id.root or state.git_root
    RightView.show(state, target.id.node, target.id.base, narrow(), root)
  end)

  return M
end

return L
