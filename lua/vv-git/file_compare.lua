-- 单文件 ref 对比：在当前 tab 中用 Neovim 原生分屏展示 ref 与当前 buffer/worktree
local M = {}

local Git = require('vv-git.git')
local UGit = require('vv-utils.git')

---@param lines string[]
---@param filetype string
---@param name string
---@return integer buf
local function create_buffer(lines, filetype, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

---@param ref string
---@param opts VVGitCompareFileOpts
---@return {root:string, relpath:string, path:string, bufnr:integer, filetype:string}?
local function resolve_source(ref, opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local path = opts.path

  if not path then
    if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    path = vim.api.nvim_buf_get_name(bufnr)
  end
  if not path or path == '' then
    vim.notify('[vv-git] Cannot compare an unnamed buffer with ' .. ref, vim.log.levels.WARN)
    return nil
  end

  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local root = opts.root and vim.fs.normalize(opts.root) or UGit.root(vim.fs.dirname(path))
  if not root or path:sub(1, #root + 1) ~= root .. '/' then
    vim.notify('[vv-git] File is not inside a Git repository: ' .. path, vim.log.levels.WARN)
    return nil
  end

  if not vim.api.nvim_buf_is_valid(bufnr) or vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) ~= path then
    bufnr = vim.fn.bufadd(path)
    local ok = pcall(vim.fn.bufload, bufnr)
    if not ok or not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.notify('[vv-git] Cannot load file: ' .. path, vim.log.levels.ERROR)
      return nil
    end
  end

  return {
    root = root,
    relpath = path:sub(#root + 2),
    path = path,
    bufnr = bufnr,
    filetype = vim.bo[bufnr].filetype,
  }
end

local DIFF_OPTS = {
  'diff',
  'scrollbind',
  'cursorbind',
  'foldmethod',
  'foldexpr',
  'foldlevel',
  'foldenable',
  'foldcolumn',
  'foldtext',
  'wrap',
}

---@param win integer
---@return table<string, any>
local function save_winopts(win)
  local saved = {}
  for _, option in ipairs(DIFF_OPTS) do
    saved[option] = vim.api.nvim_get_option_value(option, { win = win })
  end
  return saved
end

---@param win integer
---@param saved table<string, any>
local function restore_winopts(win, saved)
  if not vim.api.nvim_win_is_valid(win) then return end
  for option, value in pairs(saved) do
    vim.api.nvim_set_option_value(option, value, { win = win, scope = 'local' })
  end
end

---@param buf integer
---@param lhs string
---@return table?
local function save_buf_mapping(buf, lhs)
  if not vim.api.nvim_buf_is_valid(buf) then return nil end

  local mapping
  vim.api.nvim_buf_call(buf, function()
    local current = vim.fn.maparg(lhs, 'n', false, true)
    if type(current) == 'table' and current.buffer == 1 and next(current) then
      mapping = current
    end
  end)
  return mapping
end

---@param buf integer
---@param lhs string
---@param mapping table?
local function restore_buf_mapping(buf, lhs, mapping)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
  if not mapping then return end

  vim.api.nvim_buf_call(buf, function()
    vim.fn.mapset('n', false, mapping)
  end)
end

---@param ref string
---@param opts? VVGitCompareFileOpts
function M.open(ref, opts)
  opts = opts or {}
  if not ref or ref == '' then return end

  local function restore_caller()
    if type(opts.on_close) == 'function' then vim.schedule(opts.on_close) end
  end

  local source = resolve_source(ref, opts)
  if not source then
    restore_caller()
    return
  end

  Git.show(source.root, ref, source.relpath, function(ref_lines, err)
    if not ref_lines then
      vim.notify('[vv-git] File compare failed: ' .. (err or 'git show failed'), vim.log.levels.ERROR)
      restore_caller()
      return
    end

    local source_win = opts.winid
    if not source_win or not vim.api.nvim_win_is_valid(source_win)
        or vim.api.nvim_win_get_buf(source_win) ~= source.bufnr then
      source_win = vim.fn.win_findbuf(source.bufnr)[1]
    end
    if not source_win or not vim.api.nvim_win_is_valid(source_win) then
      source_win = vim.api.nvim_get_current_win()
    end

    local previous_buf = vim.api.nvim_win_get_buf(source_win)
    local replaced_source = previous_buf ~= source.bufnr
    if replaced_source then vim.api.nvim_win_set_buf(source_win, source.bufnr) end

    local token = tostring(vim.uv.hrtime())
    local ref_buf = create_buffer(
      ref_lines,
      source.filetype,
      'vv-git://file/' .. token .. '/' .. ref .. '/' .. source.relpath
    )

    local source_winopts = save_winopts(source_win)
    local source_mappings = {
      q = save_buf_mapping(source.bufnr, 'q'),
      ['<Esc>'] = save_buf_mapping(source.bufnr, '<Esc>'),
    }
    vim.api.nvim_set_current_win(source_win)
    vim.cmd('leftabove vsplit')
    local ref_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(ref_win, ref_buf)

    for _, win in ipairs({ ref_win, source_win }) do
      vim.api.nvim_win_call(win, function() vim.cmd('diffthis') end)
      vim.w[win].vv_statuscol_git_disabled = true
    end

    local closing = false
    local function close()
      if closing then return end
      closing = true

      for _, win in ipairs({ ref_win, source_win }) do
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_call(win, function() pcall(vim.cmd, 'diffoff') end)
          vim.w[win].vv_statuscol_git_disabled = nil
        end
      end

      if vim.api.nvim_win_is_valid(ref_win) then
        vim.api.nvim_win_close(ref_win, true)
      end
      restore_winopts(source_win, source_winopts)

      restore_buf_mapping(source.bufnr, 'q', source_mappings.q)
      restore_buf_mapping(source.bufnr, '<Esc>', source_mappings['<Esc>'])
      if replaced_source and vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_buf_is_valid(previous_buf) then
        vim.api.nvim_win_set_buf(source_win, previous_buf)
      end

      if type(opts.on_close) == 'function' then vim.defer_fn(opts.on_close, 20) end
    end

    for _, buf in ipairs({ ref_buf, source.bufnr }) do
      vim.keymap.set('n', 'q', close, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = 'vv-git: close file compare',
      })
      vim.keymap.set('n', '<Esc>', close, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = 'vv-git: close file compare',
      })
    end

    vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(ref_win),
      once = true,
      callback = function()
        if not closing then vim.schedule(close) end
      end,
    })

    vim.api.nvim_set_current_win(source_win)
  end)
end

---@class VVGitCompareFileOpts
---@field bufnr? integer Buffer used for the current side; unsaved lines are included @default current buffer
---@field path? string File used for the current side when bufnr is omitted @default current buffer path
---@field root? string Git repository root; detected from the file path when omitted
---@field on_close? fun() Called after the comparison split closes

return M
