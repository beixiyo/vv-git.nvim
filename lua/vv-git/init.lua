-- vv-git.nvim — VSCode 风 git diff 双栏视图（本地 vendor）
--
-- 架构（仿 diffview）：在专属 tabpage 里做 diff，避免与用户当前 tab 的其它窗口共享 diff-group
--   - M.open()   → `tab split` 创建新 tab，在其中放 panel + main(b_win)
--   - M.close()  → `tabclose` 整个 tab，回跳 prev_tab
--   - state 是全局单例（同时只能有一个 vv-git tab）
--
-- 公开 API：require('vv-git').{ setup | open | close | toggle | refresh }
-- 用户命令：:VVGit / :VVGitClose / :VVGitToggle / :VVGitRefresh

local HL = require('vv-git.hl')
local RightView = require('vv-git.right.view')
local Autocmds = require('vv-git.autocmds')
local Fs = require('vv-utils.fs')

local M = {}

local PERSIST_FILE = vim.fs.joinpath(vim.fn.stdpath('data'), 'vv-git.json')

---@class VVGitBinaryConfig
---@field intercept boolean  拦截二进制文件：不在 nvim 打开 diff，改用系统默认程序（仅 _activate/_goto_file；_preview 静默跳过） @default true
---@field extensions table<string, boolean>  视为二进制的扩展名集合（小写 key） @default { png = true, jpg = true, jpeg = true, ... }

---@class VVGitConfig
---@field width integer @default 30
---@field single_col_threshold integer  -- 终端列数 < 此值时 diff 视图降级为单栏（仅 b 侧，无 inline diff），≥ 此值时正常 dual diff；resize 时自动迁移 @default 120
---@field keymap_toggle_panel string|false  -- 全局切换左栏的 normal 映射；false 禁用 @default '<leader>b'
---@field fold_unchanged boolean  -- diff 视图默认折叠未改动代码 @default true
---@field diff_fill string  -- diff 空行填充符（Vim 默认 '-'），映射到 fillchars 的 diff:X @default ' '
---@field preview boolean  -- panel 中光标移动到文件行时自动刷新右侧 diff，无需手动 <CR>/o/l @default true
---@field preview_debounce_ms integer  -- 预览防抖延迟（毫秒），光标停顿后才刷新右侧 diff，避免快速 j/k 时频繁重算；0 = 不防抖 @default 150
---@field inline_diff_max_lines integer  -- 单栏模式下 inline diff 最大支持行数，超过则跳过高亮（避免 vim.diff 大文件卡） @default 10000
---@field right_click string|false  -- 右键触发的 action 名（如 'toggle_stage'/'yank_abs_path'），false 禁用 @default 'toggle_stage'
---@field diff_ratio integer[]  -- 双栏 diff 左右宽度比例，如 {4, 6} 表示 a_win:b_win = 4:6 @default { 5, 5 }
---@field diff_nowrap boolean  -- diff 视图中强制关闭 wrap（默认 true）；wrap 在双栏 diff 下因行高不一致引发视觉错位，属于上游已知限制（neovim/neovim#29518、sindrets/diffview.nvim#198） @default true
---@field highlights table<string, vim.api.keyset.highlight>?  -- 覆盖任意 VVGit* 高亮组，叠在自动计算值之上；切主题后仍生效 @default nil
---@field binary VVGitBinaryConfig
---@field keymap_select string  -- 切换当前文件选中状态的键位（默认 '<Tab>'） @default '<Tab>'
---@field select_move_down boolean  -- 多选时切换选中后自动将光标下移一行（默认 true） @default false
local defaults = {
  width = 30,
  single_col_threshold = 120,
  keymap_toggle_panel = '<leader>b',
  keymap_select = '<Tab>',
  select_move_down = false,
  fold_unchanged = true,
  diff_ratio = { 5, 5 },
  diff_fill = ' ',
  preview = true,
  preview_debounce_ms = 150,
  inline_diff_max_lines = 10000,
  right_click = 'toggle_stage',
  diff_nowrap = true,
  binary = {
    intercept = true,
    extensions = {
      png = true, jpg = true, jpeg = true, gif = true, webp = true, avif = true,
      bmp = true, ico = true, tiff = true, tif = true, psd = true, raw = true,
      heic = true, heif = true, svgz = true,
      mp4 = true, mkv = true, avi = true, mov = true, wmv = true, flv = true, webm = true,
      mp3 = true, wav = true, flac = true, aac = true, ogg = true, wma = true, m4a = true,
      zip = true, tar = true, gz = true, tgz = true, bz2 = true, tbz2 = true,
      xz = true, txz = true, ['7z'] = true, rar = true, zst = true, lz4 = true, lzma = true,
      jar = true, war = true, ear = true,
      deb = true, rpm = true, dmg = true, iso = true, apk = true, ipa = true,
      exe = true, dll = true, so = true, dylib = true, o = true, a = true,
      class = true, pyc = true, wasm = true, bin = true,
      ttf = true, otf = true, woff = true, woff2 = true, eot = true,
      pdf = true, doc = true, docx = true, xls = true, xlsx = true, ppt = true, pptx = true,
      sqlite = true, db = true,
    },
  },
}

M._config = vim.deepcopy(defaults)

---@param opts VVGitConfig?
function M.setup(opts)
  M._config = vim.tbl_deep_extend('force', defaults, opts or {})

  local persisted = Fs.load_json(PERSIST_FILE)
  if persisted.width then M._config.width = persisted.width end

  HL.setup({ highlights = M._config.highlights })

  RightView.configure({
    get_config        = function() return M._config end,
    on_close          = function() M.close() end,
    on_goto_file      = function() M._goto_file() end,
    on_yank_abs_path  = function() M._yank_abs_path() end,
  })

  local function ucmd(name, fn, cfg)
    vim.api.nvim_create_user_command(name, fn, cfg or {})
  end
  ucmd('VVGit',             function() M.open() end)
  ucmd('VVGitClose',        function() M.close() end)
  ucmd('VVGitToggle',       function() M.toggle() end)
  ucmd('VVGitTogglePanel',  function() M.toggle_panel() end)
  ucmd('VVGitRefresh',      function() M.refresh() end)
  ucmd('VVGitCompare',      function() M.open() M._compare_pick() end)
  ucmd('VVGitCommitShow',   function() M.open() M._commit_show_pick() end)
  ucmd('VVGitShow',         function(o) M.show_commit(o.args) end, { nargs = 1 })

  if M._config.keymap_toggle_panel then
    vim.keymap.set('n', M._config.keymap_toggle_panel, function() M.toggle_panel() end, {
      silent = true, desc = 'vv-git: toggle panel',
    })
  end

  pcall(function()
    local parts = vim.split(vim.o.diffopt, ',', { plain = true })
    local kept = {}
    for _, p in ipairs(parts) do
      if p ~= '' and not p:match('^linematch:') and not p:match('^inline:') then
        kept[#kept + 1] = p
      end
    end
    kept[#kept + 1] = 'linematch:60'
    kept[#kept + 1] = 'inline:char'
    vim.o.diffopt = table.concat(kept, ',')
  end)
  pcall(function() vim.opt.scrollopt:append('hor') end)
  pcall(function() vim.opt.fillchars:append({ diff = M._config.diff_fill or ' ' }) end)

  Autocmds.setup({
    on_refresh          = function() M.refresh() end,
    on_apply_layout     = function() M._apply_layout() end,
    on_ensure_invariant = function() M._ensure_invariant() end,
    on_reshow_view      = function() M._reshow_view() end,
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function()
      local State = require('vv-git.state')
      if not State.has() then return end
      local s = State.get()
      if s._panel_width then
        Fs.save_json(PERSIST_FILE, { width = s._panel_width })
      end
    end,
  })
end

---@return table
function M.config() return M._config end

--- 打开面板并直接展示指定 commit 的 diff（commit^..commit，初始 commit 用 empty-tree）。
--- 供外部集成调用（如 telescope git_log 选中 commit 后展示），跳过 vv-git 自己的 picker。
---@param hash string
---@param on_close? fun()  面板关闭（按 q）后回调，用于回到调用方 UI（如 resume telescope）
function M.show_commit(hash, on_close)
  if not hash or hash == '' then return end
  M.open()
  M._commit_show(hash)

  if on_close then
    -- 面板开在独立 tabpage，按 q → M.close → tabclose；挂一次性 WinClosed 在面板窗口上，
    -- 关闭时回调（schedule 到 tab 关完、已切回原 tab 后再执行）。
    local State = require('vv-git.state')
    local s = State.has() and State.get() or nil
    local win = s and s.panel and s.panel.win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(win),
        once = true,
        callback = function() vim.schedule(on_close) end,
      })
    end
  end
end

-- 子模块往 M 上挂方法（open/close/toggle/_preview/_activate/_commit 等）
require('vv-git.core.lifecycle').attach(M)
require('vv-git.core.panel_ops').attach(M)
require('vv-git.core.commands').attach(M)

return M
