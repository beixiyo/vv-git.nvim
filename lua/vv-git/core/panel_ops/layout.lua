-- panel 布局：保持 panel 唯一性、响应窗口尺寸变化并恢复 diff 比例

local State = require('vv-git.state')
local RightView = require('vv-git.right.view')
local Timer = require('vv-utils.timer')

local L = {}

---@param state table
local function ensure_unique_panel(state)
  local panel = state.panel
  if not panel or not panel.buf or not state.tabpage then return end

  local keeper, closed = require('vv-utils.ui_window').ensure_unique_buffer_window(
    state.tabpage,
    panel.buf,
    panel.win
  )
  panel.win = keeper

  local view = state.view
  if not view or #closed == 0 then return end

  for _, win in ipairs(closed) do
    if panel.main_win == win then panel.main_win = nil end
    for _, key in ipairs({ 'a_win', 'b_win', 'c_win' }) do
      if view[key] == win then view[key] = nil end
    end
  end
end

---@param state table
---@param ratio number[]?
function L.apply_diff_ratio(state, ratio)
  local view = state.view
  if not view or view.mode ~= 'diff2' then return end
  if not view.a_win or not vim.api.nvim_win_is_valid(view.a_win) then return end
  if not view.b_win or not vim.api.nvim_win_is_valid(view.b_win) then return end
  if not ratio or not ratio[1] or not ratio[2] then return end

  local sum = ratio[1] + ratio[2]
  if sum <= 0 then return end

  local total = vim.api.nvim_win_get_width(view.a_win)
      + vim.api.nvim_win_get_width(view.b_win)
  vim.api.nvim_win_set_width(view.a_win, math.floor(total * ratio[1] / sum))
end

---@param context table
---@return table
function L.new(context)
  local M = {}
  local function config() return context.config() end
  local function narrow() return context.narrow() end

  local function apply_layout(state)
    if not state.git_root then return end
    local view = state.view
    if not view or not view.node then return end
    -- VimResized 是防抖执行的，可能晚于文件导航到达。旧 view 不拥有最新 show
    -- request 时只等待新请求 attach，不能用旧节点重新 show 覆盖它
    if not RightView.is_attached_current(state) then return end
    if view.intrinsic_single then return end

    local want_single = narrow()
    local is_now_single = (view.mode == 'single')
    if want_single == is_now_single then
      if not want_single then
        L.apply_diff_ratio(state, config().diff_ratio)
      end
      return
    end

    RightView.show(state, view.node, view.section, want_single, view.root)
  end

  -- resize 去抖单例：L.new 仅初始化时调一次，常驻一个 uv timer
  local apply_layout_debounced = Timer.debounce(function()
    if State.has() then apply_layout(State.get()) end
  end, 50)

  M._apply_layout = State.guarded(function(state)
    ensure_unique_panel(state)
    apply_layout_debounced()
  end)

  return M
end

return L
