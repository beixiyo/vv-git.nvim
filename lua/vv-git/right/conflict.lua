-- 冲突视图机制：revision winbar、hunk 解析与接受、冲突专属 buffer keymap

local api = vim.api
local Git = require('vv-git.git')

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

-- 解析 diff3/zdiff3 或普通格式的冲突 hunk，坐标均为 1-based。
---@param buf integer
---@return table[] hunks, string[] lines
local function find_hunks(buf)
  local hunks = {}
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local index = 1

  while index <= #lines do
    if lines[index]:match('^<<<<<<< ') or lines[index] == '<<<<<<<' then
      local hunk = { start1 = index }
      index = index + 1
      while index <= #lines and not lines[index]:match('^=======') do
        if not hunk.base1
            and (lines[index]:match('^||||||| ') or lines[index] == '|||||||') then
          hunk.base1 = index
        end
        index = index + 1
      end
      if index > #lines then break end

      hunk.sep1 = index
      index = index + 1
      while index <= #lines
          and not (lines[index]:match('^>>>>>>> ') or lines[index] == '>>>>>>>') do
        index = index + 1
      end
      if index > #lines then break end

      hunk.finish1 = index
      hunks[#hunks + 1] = hunk
      index = index + 1
    else
      index = index + 1
    end
  end

  return hunks, lines
end

---@param hunks table[]
---@param cursor_line integer
---@return table?
local function nearest_hunk(hunks, cursor_line)
  for _, hunk in ipairs(hunks) do
    if cursor_line >= hunk.start1 and cursor_line <= hunk.finish1 then return hunk end
  end

  local best, best_distance = hunks[1], math.huge
  for _, hunk in ipairs(hunks) do
    local distance = math.abs(hunk.start1 - cursor_line)
    if distance < best_distance then
      best = hunk
      best_distance = distance
    end
  end
  return best
end

---@param buf integer
---@param hunk table
---@param side 'ours'|'theirs'
---@param lines string[]
local function resolve_hunk(buf, hunk, side, lines)
  local replacement = {}
  if side == 'ours' then
    -- diff3 的 base 段不属于 ours；普通格式则仍截取到分隔线之前。
    local ours_end = (hunk.base1 or hunk.sep1) - 1
    for index = hunk.start1 + 1, ours_end do
      replacement[#replacement + 1] = lines[index]
    end
  else
    for index = hunk.sep1 + 1, hunk.finish1 - 1 do
      replacement[#replacement + 1] = lines[index]
    end
  end
  api.nvim_buf_set_lines(buf, hunk.start1 - 1, hunk.finish1, false, replacement)
end

---@param state table
---@param side 'ours'|'theirs'
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

  local was_last = #hunks == 1
  local hunk = nearest_hunk(hunks, cursor_line)
  if not hunk then return end
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

---@param buf integer?
---@param state table
function M.install_keymaps(buf, state)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  vim.keymap.set('n', '<', function() accept_hunk(state, 'ours') end, {
    buffer = buf,
    silent = true,
    nowait = true,
    desc = 'vv-git: accept_ours',
  })
  vim.keymap.set('n', '>', function() accept_hunk(state, 'theirs') end, {
    buffer = buf,
    silent = true,
    nowait = true,
    desc = 'vv-git: accept_theirs',
  })
end

---@param buf integer?
function M.remove_keymaps(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  pcall(vim.keymap.del, 'n', '<', { buffer = buf })
  pcall(vim.keymap.del, 'n', '>', { buffer = buf })
end

return M
