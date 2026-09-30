-- diff 窗口布局：single、dual、conflict3 的窗口发现、创建、复用与切换

local api = vim.api

local M = {}

---@class VVGitRightLayoutOpts
---@field conflict_result_ratio number
---@field on_remove_result_buffer fun(buf:integer)

---@param state table
---@return integer?
local function main_window(state)
  local main = state.panel and state.panel.main_win
  if main and api.nvim_win_is_valid(main) then return main end

  local panel_win = state.panel and state.panel.win
  local tabpage = state.tabpage
  if tabpage and api.nvim_tabpage_is_valid(tabpage) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
      if win ~= panel_win then return win end
    end
  end
  return nil
end

---@param win integer?
local function disable_scrollbar(win)
  if win and api.nvim_win_is_valid(win) then
    vim.w[win].vv_scrollbar_disabled = true
    vim.w[win].vv_statuscol_git_disabled = true
  end
end

---@param opts VVGitRightLayoutOpts
---@return table
function M.new(opts)
  local instance = {}

  ---@param win integer?
  function instance.keep_scrollbar(win)
    if win and api.nvim_win_is_valid(win) then
      vim.w[win].vv_scrollbar_disabled = nil
      vim.w[win].vv_scrollbar_always_show = true
      vim.w[win].vv_statuscol_git_disabled = true
    end
  end

  -- 确保 single/dual 布局；从 conflict3 退出时同步释放 result buffer 的专属资源
  ---@param state table
  ---@param want_dual boolean
  ---@return integer? b_win, integer? a_win
  function instance.ensure(state, want_dual)
    local view = state.view
    if view and view.c_win then
      if api.nvim_win_is_valid(view.c_win) then
        pcall(api.nvim_win_close, view.c_win, true)
      end
      if view.c_buf then opts.on_remove_result_buffer(view.c_buf) end
      view.c_win = nil
      view.c_buf = nil
    end

    local a_valid = view and view.a_win and api.nvim_win_is_valid(view.a_win)
    local b_valid = view and view.b_win and api.nvim_win_is_valid(view.b_win)

    if want_dual then
      if a_valid and b_valid then
        disable_scrollbar(view.a_win)
        return view.b_win, view.a_win
      end
      if b_valid and not a_valid then
        api.nvim_set_current_win(view.b_win)
        api.nvim_command('leftabove vsplit')
        local a_win = api.nvim_get_current_win()
        disable_scrollbar(a_win)
        return view.b_win, a_win
      end

      local main = main_window(state)
      if not main then return nil, nil end
      api.nvim_set_current_win(main)
      api.nvim_command('leftabove vsplit')
      local a_win = api.nvim_get_current_win()
      disable_scrollbar(a_win)
      return main, a_win
    end

    -- 先从 view 摘掉 a_win 再关：WinClosed 若仍在 view 里认出它，会把整个 view
    -- 当成被外部关闭而 RightView.close，废弃正在 attach 的这次 show
    if a_valid then
      local a_win = view.a_win
      view.a_win, view.a_buf = nil, nil
      pcall(api.nvim_win_close, a_win, true)
    end
    if b_valid then return view.b_win, nil end
    return main_window(state), nil
  end

  -- conflict3 先在 b 下方创建横跨 diff 区的 result，再把顶部拆成 a/b
  ---@param state table
  ---@return integer? b_win, integer? a_win, integer? c_win
  function instance.ensure_conflict(state)
    local view = state.view
    local a_valid = view and view.a_win and api.nvim_win_is_valid(view.a_win)
    local b_valid = view and view.b_win and api.nvim_win_is_valid(view.b_win)
    local c_valid = view and view.c_win and api.nvim_win_is_valid(view.c_win)

    if a_valid and b_valid and c_valid then
      disable_scrollbar(view.a_win)
      disable_scrollbar(view.c_win)
      return view.b_win, view.a_win, view.c_win
    end

    -- b_win 是布局锚点，重建时只关闭旧 a/c；先摘字段再关窗，原因同 ensure
    local old_a, old_c = view and view.a_win, view and view.c_win
    if view then
      if view.c_buf then opts.on_remove_result_buffer(view.c_buf) end
      view.a_win, view.a_buf = nil, nil
      view.c_win, view.c_buf = nil, nil
    end
    if a_valid then pcall(api.nvim_win_close, old_a, true) end
    if c_valid then pcall(api.nvim_win_close, old_c, true) end

    local main = (b_valid and view.b_win) or main_window(state)
    if not main then return nil, nil, nil end

    api.nvim_set_current_win(main)
    local total_height = api.nvim_win_get_height(main)
    local result_height = math.max(8, math.floor(total_height * opts.conflict_result_ratio))
    api.nvim_command('belowright ' .. result_height .. 'split')
    local c_win = api.nvim_get_current_win()
    disable_scrollbar(c_win)

    api.nvim_set_current_win(main)
    api.nvim_command('leftabove vsplit')
    local a_win = api.nvim_get_current_win()
    disable_scrollbar(a_win)

    return main, a_win, c_win
  end

  return instance
end

return M
