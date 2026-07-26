-- Persistent panel-width runtime.  This owns the debounce timer so setup,
-- close and VimLeavePre can release the same resource symmetrically.

local M = {}

local function valid(width)
  return type(width) == 'number' and width > 0 and width % 1 == 0
end

---@param state_handle VVStateHandle
---@return table
function M.new(state_handle)
  local save, cancel

  local function persist(state)
    if not state or not valid(state._panel_width) then return end
    state_handle:set('width', state._panel_width)
  end

  local function start_timer()
    if save then return end
    save, cancel = require('vv-utils.timer').debounce(function()
      local state = require('vv-git.state').current()
      if state then persist(state) end
    end, 120)
  end

  local function track(state)
    if not state or not state.panel or not state.panel.win then return end
    if not vim.api.nvim_win_is_valid(state.panel.win) then return end
    state._panel_width = vim.api.nvim_win_get_width(state.panel.win)
    start_timer()
    save()
  end

  local function configure(current)
    if cancel then cancel() end
    start_timer()
    local width = state_handle:get('width')
    return valid(width) and width or current.width
  end

  return {
    configure = configure,
    persist = persist,
    track = track,
    close = function()
      if cancel then cancel() end
      save, cancel = nil, nil
    end,
  }
end

return M
