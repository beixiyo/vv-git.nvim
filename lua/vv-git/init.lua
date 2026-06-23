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

---@class VVGitSubrepoConfig
---@field depth integer  扫描嵌套子仓库（独立 git 仓库 / submodule）的最大目录深度；0 = 不扫描。可用 `:VVGitSubrepoDepth <n>` 临时改（不持久化） @default 0
---@field respect_gitignore boolean  发现时是否跳过被父仓库 `.gitignore` 的目录。**HOME-as-repo（`~` 几乎忽略一切）务必保持 `false`**，否则所有子仓库都被屏蔽；常规项目想隐藏被忽略目录里的 vendored 仓库才开 `true`（注意 `node_modules` 等已由 `prune` 覆盖） @default false
---@field prune string[]  发现子仓库时**不进入扫描**的目录名列表（匹配目录 basename）。**覆盖语义**：传了就完全替换默认列表（不合并）；`.git` 始终额外跳过 @default 见下方（node_modules / .cache / .local / .cargo / .rustup 等缓存与工具链目录）
---@field scan_worktrees boolean  是否把 linked worktree 也当子仓库扫描。默认 `false`

---@class VVGitConfig
---@field width integer @default 30
---@field single_col_threshold integer  -- 终端列数 < 此值时 diff 视图降级为单栏（仅 b 侧，无 inline diff），≥ 此值时正常 dual diff；resize 时自动迁移 @default 120
---@field keymap_toggle_panel string|false  -- 全局切换左栏的 normal 映射；false 禁用 @default '<leader>b'
---@field fold_unchanged boolean  -- diff 视图默认折叠未改动代码 @default true
---@field diff_fill string  -- diff 空行填充符（Vim 默认 '-'），映射到 fillchars 的 diff:X @default ' '
---@field preview boolean  -- panel 中光标移动到文件行时自动刷新右侧 diff，无需手动 <CR>/o/l @default true
---@field auto_refresh boolean  -- BufEnter / FocusGained 时防抖刷新左栏 git 状态，捕获终端 checkout/pull、外部改文件等 @default true
---@field preview_debounce_ms integer  -- 预览防抖延迟（毫秒），光标停顿后才刷新右侧 diff，避免快速 j/k 时频繁重算；0 = 不防抖 @default 150
---@field inline_diff_max_lines integer  -- 单栏模式下 inline diff 最大支持行数，超过则跳过高亮（避免 vim.diff 大文件卡） @default 10000
---@field right_click string|false  -- 右键触发的 action 名（如 'toggle_stage'/'yank_abs_path'），false 禁用 @default 'toggle_stage'
---@field diff_ratio integer[]  -- 双栏 diff 左右宽度比例，如 {4, 6} 表示 a_win:b_win = 4:6 @default { 5, 5 }
---@field conflict_result_ratio number  -- 三栏冲突视图中底部 result/worktree 窗口的高度比例，范围 0.1~0.9 @default 0.5
---@field diff_nowrap boolean  -- 置为 true 时 diff 视图强制关闭 wrap（wrap 在双栏 diff 下因行高不一致引发视觉错位，属于上游已知限制 neovim/neovim#29518、sindrets/diffview.nvim#198） @default false
---@field highlights table<string, vim.api.keyset.highlight>?  -- 覆盖任意 VVGit* 高亮组，叠在自动计算值之上；切主题后仍生效 @default nil
---@field binary VVGitBinaryConfig
---@field keymap_select string  -- 切换当前文件选中状态的键位（默认 '<Tab>'） @default '<Tab>'
---@field select_move_down boolean  -- 多选时切换选中后自动将光标下移一行 @default true
---@field mappings table<string, fun(state:table)>?  panel buffer 内的自定义键位；value 为函数（接收 state），可覆盖内置键位或新增 @default {}
---@field subrepo VVGitSubrepoConfig  嵌套子仓库扫描
local defaults = {
  width = 30,
  single_col_threshold = 120,
  keymap_toggle_panel = '<leader>b',
  keymap_select = '<Tab>',
  select_move_down = true,
  fold_unchanged = true,
  diff_ratio = { 5, 5 },
  conflict_result_ratio = 0.5,
  diff_fill = ' ',
  preview = true,
  preview_debounce_ms = 150,
  auto_refresh = true,
  inline_diff_max_lines = 10000,
  right_click = 'toggle_stage',
  diff_nowrap = false,
  subrepo = {
    depth = 0,
    respect_gitignore = false,
    scan_worktrees = false,
    -- 不进入扫描的目录名（数组，覆盖语义：传了就整体替换；缓存/工具链目录常含大量
    -- vendored / registry 仓库，深扫时是主要噪音与耗时来源）
    prune = {
      'node_modules', 'dist', 'build', 'target', 'vendor', '.next', '.venv',
      '.cache', '.local', '.cargo', '.rustup', '.bun', '.npm', '.nvm',
      '.gradle', '.m2', '.deno', '.pnpm-store',
    },
  },
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

-- 子仓库扫描深度的运行时临时覆盖（`:VVGitSubrepoDepth` 设置）。
-- 仅存于内存、随会话存活、关面板不清、重启即失效——满足「临时改、不持久化」
---@type integer?
M._subrepo_depth_override = nil

--- 当前生效的子仓库扫描深度：临时覆盖优先，否则取 config.subrepo.depth
---@return integer
function M.get_subrepo_depth()
  if M._subrepo_depth_override ~= nil then return M._subrepo_depth_override end
  local sr = M._config and M._config.subrepo
  return (sr and sr.depth) or 0
end

--- 临时设置子仓库扫描深度（不写盘）
---@param n integer
function M.set_subrepo_depth(n)
  M._subrepo_depth_override = n
end

---@param opts VVGitConfig?
function M.setup(opts)
  M._config = vim.tbl_deep_extend('force', defaults, opts or {})

  -- subrepo.prune 用「覆盖」语义：用户传了就整体替换默认列表。
  -- tbl_deep_extend 对数组是按下标混合（传 { 'a' } 会得到 { 'a', 默认[2..] }），故显式覆盖
  if opts and opts.subrepo and opts.subrepo.prune ~= nil then
    M._config.subrepo.prune = vim.deepcopy(opts.subrepo.prune)
  end

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
  ucmd('VVGitWorktree',     function() M.open() M._worktree_pick() end)
  ucmd('VVGitShow',         function(o) M.show_commit(o.args) end, { nargs = 1 })
  ucmd('VVGitLoad',         function() end)
  ucmd('VVGitSubrepoDepth', function(o)
    if not o.args or o.args == '' then
      vim.notify('[vv-git] subrepo scan depth = ' .. M.get_subrepo_depth(), vim.log.levels.INFO)
      return
    end
    local n = tonumber(o.args)
    if not n or n < 0 or n ~= math.floor(n) then
      vim.notify('[vv-git] invalid depth: ' .. tostring(o.args) .. ' (expect integer >= 0)', vim.log.levels.ERROR)
      return
    end
    M.set_subrepo_depth(n)
    vim.notify('[vv-git] subrepo scan depth → ' .. n, vim.log.levels.INFO)
    M.refresh()
  end, { nargs = '?', desc = 'vv-git: temporarily set subrepo scan depth (not persisted)' })

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
  }, M._config)

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

--- 返回光标节点的绝对路径（文件或目录），面板未开或光标不在节点上时返回 nil
---@return string?
function M.get_node_path()
  local State = require('vv-git.state')
  if not State.has() then return nil end
  local id = require('vv-git.core.keymaps').id_under_cursor(State.get())
  if not id or not id.node then return nil end
  return vim.fs.normalize(State.get().git_root .. '/' .. id.node.relpath)
end

--- 返回光标节点对应的目录：目录节点返回自身，文件节点返回父目录
---@return string?
function M.get_node_dir()
  local State = require('vv-git.state')
  if not State.has() then return nil end
  local id = require('vv-git.core.keymaps').id_under_cursor(State.get())
  if not id or not id.node then return nil end
  local path = vim.fs.normalize(State.get().git_root .. '/' .. id.node.relpath)
  return id.node.is_dir and path or vim.fs.dirname(path)
end

return M
