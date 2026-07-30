-- vv-git.nvim — VSCode 风 git diff 双栏视图（本地 vendor）
--
-- 架构（仿 diffview）：在专属 tabpage 里做 diff，避免与用户当前 tab 的其它窗口共享 diff-group
--   - M.open()   → `tab split` 创建新 tab，在其中放 panel + main(b_win)
--   - M.close()  → `tabclose` 整个 tab，回跳 prev_tab
--   - state 是全局单例（同时只能有一个 vv-git tab）
--
-- 公开 API 只由文件末尾的 Public facade 返回；`_` 前缀方法仅供内部模块协作
-- 用户命令统一在 setup() 注册，完整清单见 README「公开接口」

local HL = require('vv-git.hl')
local RightView = require('vv-git.right.view')
local Autocmds = require('vv-git.autocmds')
local State = require('vv-git.state')

local M = {}

---@class VVGitBinaryConfig
---@field intercept boolean  拦截二进制文件：右栏显示文件属性，显式打开时改用系统默认程序 @default true
---@field extensions table<string, boolean>  内容探测的扩展名覆盖（小写 key，显式 false 可按文本处理） @default { png = true, jpg = true, jpeg = true, ... }

---@class VVGitSubrepoConfig
---@field depth integer  扫描嵌套子仓库（独立 git 仓库 / submodule）的最大目录深度；0 = 不扫描。可用 `:VVGitSubrepoDepth <n>` 临时改（不持久化） @default 0
---@field respect_gitignore boolean  发现时是否跳过被父仓库 `.gitignore` 的目录。**HOME-as-repo（`~` 几乎忽略一切）务必保持 `false`**，否则所有子仓库都被屏蔽；常规项目想隐藏被忽略目录里的 vendored 仓库才开 `true`（注意 `node_modules` 等已由 `prune` 覆盖） @default false
---@field prune string[]  发现子仓库时**不进入扫描**的目录名列表（匹配目录 basename）。**覆盖语义**：传了就完全替换默认列表（不合并）；`.git` 始终额外跳过 @default 见下方（node_modules / .cache / .local / .cargo / .rustup 等缓存与工具链目录）
---@field scan_worktrees boolean  是否把 linked worktree 也当子仓库扫描。默认 `false`

---@class VVGitConfig
---@field width integer @default 30
---@field state VVStateHandle? 左侧面板持久状态容器；默认注册 `vv-git/panel`
---@field single_col_threshold integer  -- 终端列数 < 此值时 diff 视图降级为单栏（仅 b 侧，无 inline diff），≥ 此值时正常 dual diff；resize 时自动迁移 @default 120
---@field keymap_toggle_panel string|false  -- 全局切换左栏的 normal 映射；false 禁用 @default '<leader>b'
---@field fold_unchanged boolean  -- diff 视图是否允许折叠代码；true 时默认折叠未改动代码 @default true
---@field fold_staged boolean  -- 打开面板时默认把父仓库的 Staged Changes section 折成标题行（仅此一层，子仓库块不受影响）；只在 open 时一次性写入，之后可手动展开/折叠 @default false
---@field diff_fill string  -- diff 空行填充符（Vim 默认 '-'），映射到 fillchars 的 diff:X @default ' '
---@field preview boolean  -- panel 中光标移动到文件行时自动刷新右侧 diff，无需手动 <CR>/o/l @default true
---@field auto_refresh boolean  -- BufEnter / FocusGained 时防抖刷新左栏 git 状态，捕获终端 checkout/pull、外部改文件等 @default true
---@field preview_debounce_ms integer  -- 预览防抖延迟（毫秒），光标停顿后才刷新右侧 diff，避免快速 j/k 时频繁重算；0 = 不防抖 @default 150
---@field inline_diff_max_lines integer  -- 单栏模式下 inline diff 最大支持行数，超过则跳过高亮（避免 vim.diff 大文件卡） @default 10000
---@field right_click string|false  -- 右键触发的 action 名（如 'toggle_stage'/'yank_abs_path'），false 禁用 @default 'toggle_stage'
---@field diff_ratio number[]  -- 双栏 diff 左右宽度比例，如 {4, 6} 表示 a_win:b_win = 4:6 @default { 5, 5 }
---@field conflict_result_ratio number  -- 三栏冲突视图中底部 result/worktree 窗口的高度比例，范围 0.1~0.9 @default 0.5
---@field diff_nowrap boolean  -- 置为 true 时 diff 视图强制关闭 wrap（wrap 在双栏 diff 下因行高不一致引发视觉错位，属于上游已知限制 neovim/neovim#29518、sindrets/diffview.nvim#198） @default false
---@field highlights table<string, vim.api.keyset.highlight>?  -- 覆盖任意 VVGit* 高亮组，叠在自动计算值之上；切主题后仍生效 @default nil
---@field before_open? fun():fun()?  创建 vv-git tab 前执行，可返回退出后的恢复函数；用于由配置层临时挂起互斥 UI，不让 vendor 直接依赖其它插件 @default nil
---@field binary VVGitBinaryConfig
---@field keymap_select string  -- 切换当前文件选中状态的键位（默认 '<Tab>'） @default '<Tab>'
---@field keymap_next_file string|false  -- diff buffer 内切换到下一个文件；false 禁用 @default '<C-j>'
---@field keymap_prev_file string|false  -- diff buffer 内切换到上一个文件；false 禁用 @default '<C-k>'
---@field select_move_down boolean  -- 多选时切换选中后自动将光标下移一行 @default true
---@field mappings table<string, fun(state:table)>?  panel buffer 内的自定义键位；value 为函数（接收 state），可覆盖内置键位或新增 @default {}
---@field subrepo VVGitSubrepoConfig  嵌套子仓库扫描

---@class VVGitContext
---@field root string
---@field path? string
---@field mode 'workspace'|'compare'
---@field layout? 'staged'|'diff2'|'single'|'conflict3'
---@field panel_visible boolean
---@field from_ref? string
---@field to_ref? string

---@class VVGitCallbacks
---@field on_ready? fun(context:VVGitContext)
---@field on_error? fun(message:string)
---@field on_close? fun(context:VVGitContext)

---@class VVGitOpenOpts: VVGitCallbacks
---@field root? string Git 仓库或仓库内目录；省略时从当前 cwd 探测
---@field path? string 打开后定位的仓库内相对路径或绝对路径

---@class VVGitRevisionOpts: VVGitCallbacks
---@field root? string Git 仓库或仓库内目录；省略时从当前 cwd 探测
---@field path? string 打开后定位的仓库内相对路径或绝对路径
---@type VVGitConfig
local defaults = {
  width = 30,
  state = nil,
  single_col_threshold = 120,
  keymap_toggle_panel = '<leader>b',
  keymap_select = '<Tab>',
  keymap_next_file = '<C-j>',
  keymap_prev_file = '<C-k>',
  select_move_down = true,
  fold_unchanged = true,
  fold_staged = false,
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

---@type VVGitConfig
M._config = vim.deepcopy(defaults)
local panel_width = nil

local function track_panel_width(state)
  if panel_width then panel_width.track(state) end
end

local function persist_panel_width(state)
  if not panel_width or not state or type(state._panel_width) ~= 'number' then return end
  panel_width.persist(state)
  M._config.width = state._panel_width
end

-- 子仓库扫描深度的运行时临时覆盖（`:VVGitSubrepoDepth` 设置）
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
---@return boolean ok, string? err
function M.set_subrepo_depth(n)
  if type(n) ~= 'number' or n < 0 or n ~= math.floor(n) then
    return false, 'subrepo depth must be an integer >= 0'
  end
  M._subrepo_depth_override = n
  return true
end

---@param opts VVGitConfig?
function M.setup(opts)
  local configured_state = opts and opts.state
  ---@type VVGitConfig
  local configured = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  M._config = configured
  local panel_state = configured_state or require('vv-utils.state').register('vv-git', 'panel')
  M._config.state = panel_state

  -- subrepo.prune 用「覆盖」语义：用户传了就整体替换默认列表
  -- tbl_deep_extend 对数组是按下标混合（传 { 'a' } 会得到 { 'a', 默认[2..] }），故显式覆盖
  if opts and opts.subrepo and opts.subrepo.prune ~= nil then
    M._config.subrepo.prune = vim.deepcopy(opts.subrepo.prune)
  end

  if panel_width then panel_width.close() end
  panel_width = require('vv-git.runtime.panel_width').new(panel_state)
  M._config.width = panel_width.configure(M._config)
  M._track_panel_width = track_panel_width
  M._persist_panel_width = persist_panel_width

  HL.setup({ highlights = M._config.highlights })

  RightView.configure({
    get_config        = function() return M._config end,
    on_close          = function() M.close() end,
    on_goto_file      = function() M._goto_file() end,
    on_yank_abs_path  = function() M._yank_abs_path() end,
    on_toggle_stage   = function() M._toggle_view_stage() end,
    on_next_file      = function() M._navigate_view_file(1) end,
    on_prev_file      = function() M._navigate_view_file(-1) end,
  })

  local function ucmd(name, fn, cfg)
    vim.api.nvim_create_user_command(name, fn, vim.tbl_extend('force', { force = true }, cfg or {}))
  end
  ucmd('VVGit',             function() M.open() end)
  ucmd('VVGitClose',        function() M.close() end)
  ucmd('VVGitToggle',       function() M.toggle() end)
  ucmd('VVGitTogglePanel',  function() M.toggle_panel() end)
  ucmd('VVGitRefresh',      function() M.refresh() end)
  ucmd('VVGitCompare',      function() M.open() M._compare_pick() end)
  ucmd('VVGitCompareRef',   function(o) M.compare_with_head(o.args) end, { nargs = 1 })
  ucmd('VVGitCompareRefs',  function(o)
    if #o.fargs ~= 2 then
      vim.notify('[vv-git] VVGitCompareRefs expects exactly two refs', vim.log.levels.ERROR)
      return
    end
    M.compare_refs(o.fargs[1], o.fargs[2])
  end, { nargs = '+' })
  ucmd('VVGitCompareFile',  function(o) M.compare_file(o.args) end, { nargs = 1 })
  ucmd('VVGitCompareStop',  function() M.stop_compare() end)
  ucmd('VVGitCommitShow',   function() M.open() M._commit_show_pick() end)
  ucmd('VVGitWorktree',     function() M.open() M._worktree_pick() end)
  ucmd('VVGitPublish',      function() M.open() M._publish() end)
  ucmd('VVGitShow',         function(o) M.show_commit(o.args) end, { nargs = 1 })
  ucmd('VVGitLoad',         function() end)
  ucmd('VVGitSubrepoDepth', function(o)
    if not o.args or o.args == '' then
      vim.notify('[vv-git] subrepo scan depth = ' .. M.get_subrepo_depth(), vim.log.levels.INFO)
      return
    end
    local n = tonumber(o.args)
    if not n then
      vim.notify('[vv-git] invalid depth: ' .. tostring(o.args), vim.log.levels.ERROR)
      return
    end
    local ok, err = M.set_subrepo_depth(n)
    if not ok then
      vim.notify('[vv-git] invalid depth: ' .. tostring(o.args) .. ' (' .. err .. ')', vim.log.levels.ERROR)
      return
    end
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
    on_closed           = function(state)
      panel_width.persist(state)
      panel_width.close()
      M._emit_closed(state)
    end,
    on_external_root    = function(dir) M._follow_external_root(dir) end,
  }, M._config)

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('VVGitPersist', { clear = true }),
    callback = function()
      if State.has() then
        panel_width.track(State.get())
        panel_width.persist(State.get())
      end
      if panel_width then panel_width.close() end
    end,
  })
end

---@return VVGitConfig
function M.config()
  return vim.deepcopy(M._config)
end

---@param fn function?
---@param ... any
function M._invoke_callback(fn, ...)
  if type(fn) ~= 'function' then return end
  local args = { ... }
  vim.schedule(function()
    local ok, err = pcall(fn, vim.F.unpack_len(args))
    if not ok then
      vim.notify('[vv-git] callback failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---@param state table
---@return VVGitContext
function M._context(state)
  local compare = state.compare
  local view = state.view
  return {
    root = state.git_root,
    path = state.cur_path,
    mode = compare and 'compare' or 'workspace',
    layout = view and view.mode or nil,
    panel_visible = state.panel ~= nil
        and state.panel.win ~= nil
        and vim.api.nvim_win_is_valid(state.panel.win),
    from_ref = compare and compare.from_rev or nil,
    to_ref = compare and compare.to_rev or nil,
  }
end

---@param state table
---@param on_close function?
function M._register_on_close(state, on_close)
  if type(on_close) ~= 'function' then return end
  state._on_close = state._on_close or {}
  for _, callback in ipairs(state._on_close) do
    if callback == on_close then return end
  end
  state._on_close[#state._on_close + 1] = on_close
end

---@param state table
function M._emit_closed(state)
  local callbacks = state._on_close or {}
  state._on_close = nil
  local resume = state._resume_after_close
  state._resume_after_close = nil
  local context = M._context(state)
  for _, callback in ipairs(callbacks) do
    M._invoke_callback(callback, context)
  end
  M._invoke_callback(resume)
end

---@return boolean
function M.is_open()
  if not State.has() then return false end
  local state = State.get()
  return state.tabpage ~= nil and vim.api.nvim_tabpage_is_valid(state.tabpage)
end

---@return VVGitContext?
function M.get_context()
  if not M.is_open() then return nil end
  return M._context(State.get())
end

--- 打开面板并直接展示指定 commit 的 diff（commit^..commit，初始 commit 用 empty-tree）
--- 供外部集成调用（如 telescope git_log 选中 commit 后展示），跳过 vv-git 自己的 picker
---@param ref string
---@param opts? VVGitRevisionOpts
---@return boolean started
function M.show_commit(ref, opts)
  opts = opts or {}
  if not ref or ref == '' then
    M._invoke_callback(opts.on_error, 'ref is required')
    return false
  end
  local opened = M.open({
    root = opts.root,
    path = opts.path,
    on_close = opts.on_close,
    on_error = opts.on_error,
  })
  if not opened then return false end
  M._commit_show(ref, opts.on_ready, opts.on_error)
  return true
end

--- 打开面板并比较任意 Git ref 与 HEAD（ref..HEAD）
---@param ref string
---@param opts? VVGitRevisionOpts
---@return boolean started
function M.compare_with_head(ref, opts)
  return M.compare_refs(ref, 'HEAD', opts)
end

--- 打开面板并比较任意两个 Git ref（from_ref..to_ref）
---@param from_ref string
---@param to_ref string
---@param opts? VVGitRevisionOpts
---@return boolean started
function M.compare_refs(from_ref, to_ref, opts)
  opts = opts or {}
  if not from_ref or from_ref == '' or not to_ref or to_ref == '' then
    M._invoke_callback(opts.on_error, 'from_ref and to_ref are required')
    return false
  end
  local opened = M.open({
    root = opts.root,
    path = opts.path,
    on_close = opts.on_close,
    on_error = opts.on_error,
  })
  if not opened then return false end
  M._compare_refs(from_ref, to_ref, opts.on_ready, opts.on_error)
  return true
end

--- 在当前 tab 的原生分屏中比较指定 ref 与当前 buffer / worktree 文件
---@param ref string
---@param opts? VVGitCompareFileOpts
function M.compare_file(ref, opts)
  return require('vv-git.file_compare').open(ref, opts)
end

--- 退出当前面板的 ref 比较模式，返回普通工作区变更视图
function M.stop_compare()
  return M._compare_stop()
end

-- Runtime services are composed explicitly.  Each module owns and returns its
-- operations; none receives the entry module as a mutable injection target.
local services = {
  controller = M,
  config = function() return M._config end,
  track_panel_width = track_panel_width,
  persist_panel_width = persist_panel_width,
}

for _, operations in ipairs({
  require('vv-git.core.lifecycle').new(services),
  require('vv-git.core.panel_ops').new(services),
  require('vv-git.core.commands').new(services),
}) do
  for name, operation in pairs(operations) do
    M[name] = operation
  end
end

--- 返回光标节点的绝对路径（文件或目录），面板未开或光标不在节点上时返回 nil
---@return string?
function M.get_node_path()
  if not State.has() then return nil end
  local state = State.get()
  local id = require('vv-git.core.keymaps').id_under_cursor(state)
  if not id or not id.node then return nil end
  local root = select(1, require('vv-git.subrepo').parse_section_id(id.section or ''))
  return vim.fs.normalize((root or state.git_root) .. '/' .. id.node.relpath)
end

--- 返回当前操作目标的绝对路径；存在多选时返回全部选中文件，否则返回光标节点
---@return string[]
function M.get_target_paths()
  if not State.has() then return {} end

  local state = State.get()
  local Subrepo = require('vv-git.subrepo')
  local unique = {}

  for key in pairs(state.selection or {}) do
    local root, _, relpath = Subrepo.parse_sel_key(key)
    if relpath then
      unique[vim.fs.normalize((root or state.git_root) .. '/' .. relpath)] = true
    end
  end

  local paths = vim.tbl_keys(unique)
  table.sort(paths)
  if #paths > 0 then return paths end

  local path = M.get_node_path()
  return path and { path } or {}
end

--- 返回光标节点对应的目录：目录节点返回自身，文件节点返回父目录
---@return string?
function M.get_node_dir()
  if not State.has() then return nil end
  local state = State.get()
  local id = require('vv-git.core.keymaps').id_under_cursor(state)

  if not id or not id.node then return nil end
  local root = select(1, require('vv-git.subrepo').parse_section_id(id.section or ''))
  local path = vim.fs.normalize((root or state.git_root) .. '/' .. id.node.relpath)

  return id.node.is_dir and path or vim.fs.dirname(path)
end

local Public = {}
for _, name in ipairs({
  'setup', 'config',
  'get_subrepo_depth', 'set_subrepo_depth',
  'open', 'close', 'toggle', 'toggle_panel', 'refresh',
  'is_open', 'get_context',
  'show_commit', 'compare_with_head', 'compare_refs', 'compare_file', 'stop_compare',
  'get_node_path', 'get_target_paths', 'get_node_dir',
}) do
  Public[name] = M[name]
end

return Public
