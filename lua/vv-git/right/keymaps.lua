-- diff buffer 的快捷键生命周期、原生 fold 映射与跨窗口 fold 切换

local api = vim.api
local Scroll = require('vv-utils.scroll')

local M = {}

---@class VVGitRightKeymapCallbacks
---@field close fun()
---@field goto_file fun()
---@field yank_abs_path fun()
---@field toggle_stage fun()
---@field next_file fun()
---@field prev_file fun()

---@class VVGitRightKeymapOpts
---@field callbacks VVGitRightKeymapCallbacks
---@field next_file_key string|false
---@field prev_file_key string|false
---@field revision_mappings table<string, fun(context:VVGitRevisionMappingContext)>

-- fold 键全部包成 buffer-local 原生命令，绕过用户的全局 ufo 映射：
-- ufo.openAllFolds 只执行 `:%foldopen!`，不会更新 foldlevel；而 diff 窗口把
-- foldlevel 锁在 0，后续重绘、滚动或第三方 WinScrolled 回调重新计算 fold 时，
-- 这些 fold 会再次塌回去。原生 `zR` 会同步抬高 foldlevel，不会发生回弹
--
-- 必须完整列出 za/zA/zo/zc/zR/...：任何漏掉的 fold 命令仍可能落入 ufo 的全局
-- mapping，重新引入相同的 snap-back。这里是维护契约，不应简化为只覆盖 zR/zM
local FOLD_CMDS = {
  'za', 'zA', 'ze', 'zE', 'zo', 'zc', 'zO', 'zC',
  'zr', 'zm', 'zR', 'zM', 'zv', 'zx', 'zX', 'zn', 'zN', 'zi',
}

---@param direction ']'|'['
local function jump_diff_chunk(direction)
  local win = api.nvim_get_current_win()
  if not api.nvim_get_option_value('diff', { win = win }) then return end

  Scroll.with_view_animation(win, function()
    pcall(api.nvim_command, 'normal! ' .. direction .. 'czz')
  end)
end

---@param view table
---@return integer[]
local function fold_windows(view)
  local wins = {}
  for _, key in ipairs({ 'a_win', 'b_win' }) do
    local win = view[key]
    if win and api.nvim_win_is_valid(win)
        and api.nvim_get_option_value('foldenable', { win = win }) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

---@param win integer
---@return boolean
local function has_closed_folds(win)
  return api.nvim_win_call(win, function()
    local count = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
    for row = 1, count do
      if vim.fn.foldclosed(row) > 0 then return true end
    end
    return false
  end)
end

---@param opts VVGitRightKeymapOpts
---@return table
function M.new(opts)
  local callbacks = opts.callbacks
  local specs = {
    { 'q',     callbacks.close,          'close' },
    { '<Esc>', callbacks.close,          'close' },
    { 'gf',    callbacks.goto_file,      'goto_file' },
    { 'Y',     callbacks.yank_abs_path,  'yank_abs_path' },
    { '-',     callbacks.toggle_stage,   'toggle_stage' },
    { ']c',    function() jump_diff_chunk(']') end, 'next_chunk' },
    { '[c',    function() jump_diff_chunk('[') end, 'prev_chunk' },
  }

  if opts.next_file_key then
    specs[#specs + 1] = { opts.next_file_key, callbacks.next_file, 'next_file' }
  end
  if opts.prev_file_key then
    specs[#specs + 1] = { opts.prev_file_key, callbacks.prev_file, 'prev_file' }
  end
  for _, cmd in ipairs(FOLD_CMDS) do
    specs[#specs + 1] = {
      cmd,
      function() pcall(api.nvim_command, 'normal! ' .. cmd) end,
      'fold ' .. cmd,
    }
  end

  local instance = {}

  ---@param buf integer?
  function instance.install(buf)
    if not buf or not api.nvim_buf_is_valid(buf) then return end
    for _, lhs in ipairs(vim.b[buf].vv_git_right_keys or {}) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end

    local installed = {}
    for _, spec in ipairs(specs) do
      vim.keymap.set('n', spec[1], spec[2], {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = 'vv-git: ' .. spec[3],
      })
      installed[#installed + 1] = spec[1]
    end

    -- worktree buffer 可能已有 LspAttach 等来源的 buffer-local 映射。自定义右栏
    -- 行为只补到 vv-git 自建的 revision/index scratch，避免关闭视图时误删原映射
    if vim.b[buf].vv_git_scratch then
      for lhs, action in pairs(opts.revision_mappings or {}) do
        if type(action) == 'function' then
          vim.keymap.set('n', lhs, function()
            action({
              bufnr = buf,
              winid = api.nvim_get_current_win(),
              source_path = vim.b[buf].vv_git_source_path,
            })
          end, {
            buffer = buf,
            silent = true,
            nowait = true,
            desc = 'vv-git: revision custom: ' .. lhs,
          })
          installed[#installed + 1] = lhs
        end
      end
    end
    vim.b[buf].vv_git_right_keys = installed
  end

  ---@param buf integer?
  function instance.remove(buf)
    if not buf or not api.nvim_buf_is_valid(buf) then return end
    for _, lhs in ipairs(vim.b[buf].vv_git_right_keys or {}) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
    vim.b[buf].vv_git_right_keys = nil
  end

  ---@param buf integer?
  function instance.block_insert(buf)
    if not buf or not api.nvim_buf_is_valid(buf) then return end
    for _, key in ipairs({ 'i', 'I', 'a', 'A', 'o', 'O', 's', 'S', 'c', 'C', 'R' }) do
      vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true })
    end
  end

  ---@param view table
  ---@return boolean handled
  function instance.toggle_all_folds(view)
    local wins = fold_windows(view)
    if #wins == 0 then return false end

    local open_all = false
    for _, win in ipairs(wins) do
      if has_closed_folds(win) then
        open_all = true
        break
      end
    end

    local cmd = open_all and 'zR' or 'zM'
    for _, win in ipairs(wins) do
      api.nvim_win_call(win, function()
        pcall(api.nvim_command, 'normal! ' .. cmd)
      end)
    end
    pcall(function() require('vv-statuscol').refresh() end)
    return true
  end

  return instance
end

return M
