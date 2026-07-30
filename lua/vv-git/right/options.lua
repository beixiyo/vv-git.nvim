-- diff 窗口选项的保存、应用与恢复；配置在构造时归一化为具体值

local api = vim.api

local M = {}

---@class VVGitRightOptionsConfig
---@field fold_unchanged boolean
---@field diff_nowrap boolean

local CHANGED_OPTS = {
  'diff',
  'scrollbind',
  'cursorbind',
  'foldmethod',
  'foldexpr',
  'foldlevel',
  'foldenable',
  'foldcolumn',
  'foldtext',
  'winhighlight',
  'wrap',
  'winbar',
}

local WINHL = {
  a = table.concat({
    'DiffAdd:VVGitDiffAddAsDelete',
    'DiffDelete:VVGitDiffDeleteDim',
    'DiffChange:VVGitDiffChangeDelete',
    'DiffText:VVGitDiffTextDelete',
    'DiffTextAdd:VVGitDiffTextAddDelete',
    'Folded:VVGitFold',
  }, ','),
  b = table.concat({
    'DiffAdd:VVGitDiffAdd',
    'DiffDelete:VVGitDiffDeleteDim',
    'DiffChange:VVGitDiffChange',
    'DiffText:VVGitDiffText',
    'DiffTextAdd:VVGitDiffTextAdd',
    'Folded:VVGitFold',
  }, ','),
}

---@param config VVGitRightOptionsConfig
---@return table
function M.new(config)
  local instance = {}

  ---@param win integer
  function instance.save(win)
    if not api.nvim_win_is_valid(win) then return end
    -- 复用窗口时不覆盖：不能把已经 diff 化的值当成用户原始配置
    if vim.w[win].vv_git_saved then return end

    local saved = {}
    for _, opt in ipairs(CHANGED_OPTS) do
      saved[opt] = api.nvim_get_option_value(opt, { win = win })
    end
    vim.w[win].vv_git_saved = saved
  end

  ---@param win integer
  function instance.restore(win)
    if not api.nvim_win_is_valid(win) then return end
    local saved = vim.w[win].vv_git_saved
    if not saved then return end

    for opt, value in pairs(saved) do
      pcall(api.nvim_set_option_value, opt, value, { win = win, scope = 'local' })
    end
    vim.w[win].vv_git_saved = nil
  end

  ---@param win integer
  ---@param buf integer
  ---@param side 'a'|'b'
  function instance.apply_diff(win, buf, side)
    instance.save(win)
    -- 复用 diff 窗口切 buffer 时必须先关 diff 再 set_buf 再开：Neovim 的 diff
    -- 数据按窗口维护，set_buf 不会触发重建，否则新 buffer 会沿用旧 hunk。
    if api.nvim_get_option_value('diff', { win = win }) then
      api.nvim_set_option_value('diff', false, { win = win, scope = 'local' })
    end

    -- E828 等场景可能在 buffer 已成功切换后仍抛错，只传播其它异常
    local ok, err = pcall(api.nvim_win_set_buf, win, buf)
    if not ok and not tostring(err):find('E828') then error(err) end

    api.nvim_set_option_value('diff', true, { win = win, scope = 'local' })
    api.nvim_set_option_value('scrollbind', true, { win = win, scope = 'local' })
    api.nvim_set_option_value('cursorbind', true, { win = win, scope = 'local' })

    -- foldmethod=diff 必须覆盖 FileType/LspAttach 写入的 expr；foldlevel=0 必须覆盖
    -- treesitter autocmd 可能在刚创建的 a_win 上写入的 99，否则默认折叠会全部展开。
    if config.fold_unchanged then
      api.nvim_set_option_value('foldmethod', 'diff', { win = win, scope = 'local' })
      api.nvim_set_option_value('foldlevel', 0, { win = win, scope = 'local' })
    end
    api.nvim_set_option_value('foldenable', config.fold_unchanged, { win = win, scope = 'local' })
    api.nvim_set_option_value('foldcolumn', config.fold_unchanged and '1' or '0', {
      win = win,
      scope = 'local',
    })
    api.nvim_set_option_value(
      'foldtext',
      "v:lua.require'vv-git.foldtext'.render()",
      { win = win, scope = 'local' }
    )
    api.nvim_set_option_value('winhighlight', WINHL[side], { win = win, scope = 'local' })
    -- wrap 会让双栏两侧产生不同视觉行高。diff_nowrap=true 时用 nowrap 避免错位：
    -- https://github.com/neovim/neovim/issues/29518
    -- https://github.com/sindrets/diffview.nvim/issues/198
    if config.diff_nowrap then
      api.nvim_set_option_value('wrap', false, { win = win, scope = 'local' })
    end
  end

  ---@param win integer
  ---@param buf integer
  function instance.apply_result(win, buf)
    instance.save(win)

    local ok, err = pcall(api.nvim_win_set_buf, win, buf)
    if not ok and not tostring(err):find('E828') then error(err) end

    api.nvim_set_option_value('diff', false, { win = win, scope = 'local' })
    api.nvim_set_option_value('scrollbind', true, { win = win, scope = 'local' })
    api.nvim_set_option_value('cursorbind', true, { win = win, scope = 'local' })
    if config.diff_nowrap then
      api.nvim_set_option_value('wrap', false, { win = win, scope = 'local' })
    end
  end

  return instance
end

return M
