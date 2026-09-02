-- 冲突视图机制：revision winbar、hunk 解析与接受、冲突专属 buffer keymap

local api = vim.api
local Git = require('vv-git.git')
local UtilsGit = require('vv-utils.git')

local M = {}

local REF_HL = { HEAD = 'VVGitWinbarOurs', MERGE_HEAD = 'VVGitWinbarTheirs' }
local winbar_request_id = 0

---@param win integer
---@return integer
local function next_winbar_request(win)
  winbar_request_id = winbar_request_id + 1
  if api.nvim_win_is_valid(win) then
    vim.w[win].vv_git_conflict_winbar_request = winbar_request_id
  end
  return winbar_request_id
end

---@param win integer
---@param state table
---@param ref 'HEAD'|'MERGE_HEAD'
---@param root? string
function M.set_winbar(win, state, ref, root)
  root = root or state.git_root
  local branch_hl = REF_HL[ref] or 'VVGitWinbarOurs'
  local request_id = next_winbar_request(win)

  local function apply(info)
    if not api.nvim_win_is_valid(win) then return end
    if vim.w[win].vv_git_conflict_winbar_request ~= request_id then return end
    if not info then
      local label = ref == 'HEAD' and 'ours' or 'theirs'
      api.nvim_set_option_value(
        'winbar',
        '%#' .. branch_hl .. '#  ' .. label .. ' %*',
        { win = win, scope = 'local' }
      )
      return
    end

    local branch = info.branch ~= '' and info.branch or ref
    local hash = info.hash ~= '' and info.hash or ''
    local subject = info.subject
    local width = api.nvim_win_get_width(win)
    local fixed_width = vim.fn.strdisplaywidth('  ' .. branch .. '  ')
        + (hash ~= '' and vim.fn.strdisplaywidth(' ' .. hash) or 0)
    local available = width - fixed_width - 2

    if available <= 3 then
      subject = ''
    elseif vim.fn.strdisplaywidth(subject) > available then
      local low, high = 0, vim.fn.strchars(subject)
      while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if vim.fn.strdisplaywidth(vim.fn.strcharpart(subject, 0, mid) .. '…') <= available then
          low = mid
        else
          high = mid - 1
        end
      end
      subject = vim.fn.strcharpart(subject, 0, low) .. '…'
    end

    local hash_part = hash ~= '' and ('%#Comment# ' .. hash .. '%*') or ''
    local subject_part = subject ~= '' and (' ' .. subject) or ''
    local bar = '%#' .. branch_hl .. '#  ' .. branch .. ' %*' .. hash_part .. subject_part
    api.nvim_set_option_value('winbar', bar, { win = win, scope = 'local' })
  end

  local cache = state._conflict_info_cache
  if not cache then
    cache = {}
    state._conflict_info_cache = cache
  end

  -- root 进入缓存键，避免父仓库与子仓库的 HEAD/MERGE_HEAD 信息互相串用。
  local cache_key = root .. '\0' .. ref
  if cache[cache_key] ~= nil then
    apply(cache[cache_key] or nil)
    return
  end

  Git.conflict_info(root, ref, function(info)
    if cache[cache_key] == nil then cache[cache_key] = info or false end
    apply(info)
  end)
end

---@param win integer?
function M.clear_winbar(win)
  if win and api.nvim_win_is_valid(win) then
    next_winbar_request(win)
    pcall(api.nvim_set_option_value, 'winbar', '', { win = win, scope = 'local' })
  end
end

---@param state table
function M.reset(state)
  local view = state.view
  if view then
    for _, key in ipairs({ 'a_win', 'b_win', 'c_win' }) do
      M.clear_winbar(view[key])
    end
  end
  state._conflict_info_cache = nil
end

---@param buf integer
---@return vv-utils.git.ConflictHunk[] hunks, string[] lines
local function find_hunks(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  return UtilsGit.parse_conflict_hunks(lines), lines
end

---@param hunks vv-utils.git.ConflictHunk[]
---@param cursor_line integer
---@return vv-utils.git.ConflictHunk?
local function hunk_at(hunks, cursor_line)
  for _, hunk in ipairs(hunks) do
    if cursor_line >= hunk.start_line and cursor_line <= hunk.end_line then return hunk end
  end
  return nil
end

---@param hunks vv-utils.git.ConflictHunk[]
---@param cursor_line integer
---@return vv-utils.git.ConflictHunk?
local function nearest_hunk(hunks, cursor_line)
  local best, best_distance = hunks[1], math.huge
  for _, hunk in ipairs(hunks) do
    local distance = math.abs(hunk.start_line - cursor_line)
    if distance < best_distance then
      best = hunk
      best_distance = distance
    end
  end
  return best
end

---@alias VVGitConflictSide 'ours'|'theirs'|'both'

---@param buf integer
---@param hunk vv-utils.git.ConflictHunk
---@param side VVGitConflictSide  both = ours 段接 theirs 段，等价于 `git merge-file --union`
---@param lines string[]
local function resolve_hunk(buf, hunk, side, lines)
  local replacement = {}
  local function append(first, last)
    for index = first, last do replacement[#replacement + 1] = lines[index] end
  end

  if side ~= 'theirs' then
    -- diff3 / zdiff3 的 base 段不属于任何一侧；普通格式则截取到分隔线之前
    append(hunk.start_line + 1, (hunk.base_line or hunk.separator_line) - 1)
  end
  if side ~= 'ours' then
    append(hunk.separator_line + 1, hunk.end_line - 1)
  end
  api.nvim_buf_set_lines(buf, hunk.start_line - 1, hunk.end_line, false, replacement)
end

---@param state table
---@param side VVGitConflictSide
local function accept_hunk(state, side)
  local view = state.view
  if not (view and view.section == 'conflicts') then return end
  local result_buf, result_win = view.c_buf, view.c_win
  if not (result_buf and api.nvim_buf_is_valid(result_buf)) then return end

  local cursor_line = 1
  if result_win and api.nvim_win_is_valid(result_win) then
    cursor_line = api.nvim_win_get_cursor(result_win)[1]
  end

  local hunks, lines = find_hunks(result_buf)
  if #hunks == 0 then return end

  -- 只对 Result 光标所在的冲突块生效；光标在块外时把光标移到最近的块并提示，
  -- 不做任何文本改写，避免从 ours/theirs 窗口按键时意外替换看不见的块
  local hunk = hunk_at(hunks, cursor_line)
  if not hunk then
    local target = nearest_hunk(hunks, cursor_line)
    if target and result_win and api.nvim_win_is_valid(result_win) then
      pcall(api.nvim_win_set_cursor, result_win, { target.start_line, 0 })
    end
    vim.notify('[vv-git] Result cursor moved to the nearest conflict; press again to accept',
      vim.log.levels.INFO)
    return
  end

  local was_last = #hunks == 1
  resolve_hunk(result_buf, hunk, side, lines)
  pcall(api.nvim_buf_call, result_buf, function() vim.cmd('silent! write') end)

  if not was_last then return end
  local relpath = view.node and view.node.relpath
  local root = view.root or state.git_root
  if not (relpath and root) then return end

  local owner_root = state.git_root
  Git.stage(root, { relpath }, function(ok, err)
    if not ok then
      vim.notify('[vv-git] stage failed: ' .. (err or ''), vim.log.levels.ERROR)
      return
    end
    require('vv-git.loader').reload_index(state)
  end, {
    is_current = function()
      return require('vv-git.state').is_current(state)
          and not state._closing and state.git_root == owner_root
    end,
  })
end

-- `<` `>` `=` 在 normal 模式本是缩进 / 格式化操作符，冲突 buffer 内统一覆盖为接受动作；
-- `=` 对应分隔线 `=======`，表示两侧都保留
local ACCEPT_KEYS = {
  { lhs = '<', side = 'ours',   action = 'accept_ours_hunk' },
  { lhs = '>', side = 'theirs', action = 'accept_theirs_hunk' },
  { lhs = '=', side = 'both',   action = 'accept_both_hunk' },
}

---@param buf integer?
---@param state table
function M.install_keymaps(buf, state)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  for _, key in ipairs(ACCEPT_KEYS) do
    vim.keymap.set('n', key.lhs, function() accept_hunk(state, key.side) end, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = 'vv-git: ' .. key.action,
    })
  end
end

---@param buf integer?
function M.remove_keymaps(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  for _, key in ipairs(ACCEPT_KEYS) do
    pcall(vim.keymap.del, 'n', key.lhs, { buffer = buf })
  end
end

return M
