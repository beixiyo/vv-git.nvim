<div align="center">
  <h1>vv-git.nvim</h1>
  <p><a href="./README.md">English</a> | 中文</p>
  <img src="https://github.com/beixiyo/vv-git.nvim/releases/download/assets-2026-07-25/vv-git.png" alt="vv-git 演示" width="900" />
  <p>想要我的 Neovim 配置？查看 <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <em>VSCode 风格 git diff 双栏视图 — 专属 tab 隔离、自动折叠未改动代码</em>
  <p>
    <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
    <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  </p>
</div>

---

## 依赖

- [Git](https://github.com/git/git) — 必须，用于状态、diff、暂存、提交、分支、远程与 worktree 操作
- [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) — 必须，提供共享 Git 解析、文件系统与 UI 工具

## 安装

```lua
{
  'beixiyo/vv-git.nvim',
  dependencies = { 'beixiyo/vv-utils.nvim' },
  cmd = {
    'VVGit', 'VVGitClose', 'VVGitToggle', 'VVGitTogglePanel', 'VVGitRefresh',
    'VVGitCompare', 'VVGitCompareRef', 'VVGitCompareRefs', 'VVGitCompareFile',
    'VVGitCompareStop', 'VVGitCommitShow', 'VVGitWorktree', 'VVGitPublish',
    'VVGitShow', 'VVGitSubrepoDepth', 'VVGitLoad',
  },
  keys = { '<leader>b' },
  ---@type VVGitConfig
  opts = {
    width = 30,                        -- 左栏宽度
    single_col_threshold = 120,        -- 窗口列数 < 此值时降级为单栏 + inline diff
    keymap_toggle_panel = '<leader>b', -- 全局切换左栏的映射（false 禁用）
    keymap_select = '<Tab>',           -- 切换当前文件选中状态（多选）
    fold_unchanged = true,             -- 折叠未改动代码
    fold_staged = false,               -- 打开面板时默认折叠 Staged Changes section（仅此一层）
    diff_fill = ' ',                   -- diff 空行填充符（Vim 默认 '-'）
    preview = true,                    -- 光标移动到文件行时自动刷新右侧 diff
    inline_diff_max_lines = 10000,     -- 单栏 inline diff 最大行数（超过跳过高亮）
    diff_ratio = { 4, 6 },            -- 双栏 a_win:b_win 宽度比例（不填则 50:50）
    conflict_result_ratio = 0.5,       -- 三栏冲突视图底部 result/worktree 高度比例
  },
}
```

## 配置

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `width` | `integer` | `30` | 左栏宽度（字符数） |
| `single_col_threshold` | `integer` | `120` | 窗口列数低于此值时降级为单栏（仅 b 侧 + inline diff），≥ 此值双栏；resize 自动迁移 |
| `keymap_toggle_panel` | `string \| false` | `'<leader>b'` | 全局切换左栏可见性的映射；`false` 禁用 |
| `fold_unchanged` | `boolean` | `true` | 是否允许代码折叠；启用时默认折叠未改动代码（dual: `foldmethod=diff`；single: manual fold） |
| `fold_staged` | `boolean` | `false` | 自动把父仓库的 `Staged Changes` section 折成标题行（仅此一层，子仓库块不受影响） |
| `diff_fill` | `string` | `' '` | diff 空行填充符，映射到 `fillchars` 的 `diff:X` |
| `preview` | `boolean` | `true` | 光标在左栏移动时自动刷新右侧 diff，无需手动 `<CR>` |
| `inline_diff_max_lines` | `integer` | `10000` | 单栏模式下 `vim.diff` 最大支持行数，超过只显示文本不画高亮 |
| `right_click` | `string \| false` | `'toggle_stage'` | 右键触发的 action 名（如 `'yank_abs_path'`），`false` 禁用 |
| `diff_ratio` | `integer[]` | 无（50:50） | 双栏模式下 a_win（旧版本）与 b_win（工作区）的宽度比例，如 `{4, 6}` 表示左窄右宽；不填则等宽 |
| `conflict_result_ratio` | `number` | `0.5` | 三栏冲突视图中底部 result/worktree 窗口的高度比例，范围 `0.1`~`0.9` |
| `diff_nowrap` | `boolean` | `false` | 默认保持折行；置为 `true` 则 diff 视图强制关闭折行——`wrap` 在双栏模式下因两侧行高不一致会造成视觉错位，属于上游已知限制（[neovim/neovim#29518](https://github.com/neovim/neovim/issues/29518)、[diffview.nvim#198](https://github.com/sindrets/diffview.nvim/issues/198)） |
| `highlights` | `table` | 无 | 覆盖任意 `VVGit*` 高亮组，叠加在自动计算值之上，切换主题后仍生效（见下方「自定义配色」）|
| `keymap_select` | `string` | `'<Tab>'` | 切换当前行选中状态（多选）；目录节点忽略 |
| `select_move_down` | `boolean` | `true` | `<Tab>` 切换选中后自动将光标下移一行 |
| `binary.intercept` | `boolean` | `true` | 拦截二进制文件：预览时静默跳过，`<CR>`/`gf` 改用系统默认程序打开；`false` 禁用拦截 |
| `binary.extensions` | `table<string, boolean>` | 见下方 | 视为二进制的扩展名集合（小写 key）；`vim.tbl_deep_extend` 合并，只需写要覆盖的 key |
| `subrepo.depth` | `integer` | `0` | 扫描嵌套子仓库（独立 git 仓库 / submodule）的最大目录深度；`0` = 不扫描。可用 `:VVGitSubrepoDepth <n>` 临时改（不持久化） |
| `subrepo.respect_gitignore` | `boolean` | `false` | 发现时是否跳过被父仓库 `.gitignore` 的目录 |
| `subrepo.prune` | `string[]` | 见下方 | 发现子仓库时**不进入扫描**的目录名列表。**覆盖**语义：传了就整体替换默认列表（不合并）；默认含 `node_modules` / `.cache` / `.local` / `.cargo` / `.rustup` / `.bun` 等缓存目录，`.git` 始终跳过 |
| `subrepo.scan_worktrees` | `boolean` | `false` | 是否把 linked worktree 也当子仓库扫描。默认 `false` |

## vv-scrollbar 集成

同时安装 `vv-scrollbar.nvim` 时，双栏 diff 的左侧基准窗口会自动禁用滚动条，
右侧则将 marker 轨道保持常驻；staged 右侧会把 index 对 HEAD 的行级改动投影为 Git marker。
单栏和冲突结果窗口保持正常，无需额外配置

同时安装 `vv-statuscol.nvim` 时，所有 diff / result 窗口会隐藏 statuscol 的 Git 双轨，
避免与滚动条 marker 和 diff 染色重复；该控制是 window-local，同一文件在普通编辑窗口中的
staged / unstaged 双轨仍然显示

## 子仓库扫描

```lua
opts = {
  subrepo = {
    depth = 1,                  -- 从 cwd 向下扫 1 层找子仓库
    respect_gitignore = false,  -- 默认；HOME-as-repo 必须 false 才看得到 ~/code 等被 ignore 的项目
    -- prune 是数组，覆盖语义：传了就整体替换默认（默认已含 node_modules / .cache /
    -- .local / .cargo 等缓存目录）。想在默认基础上加目录，需把默认项一并列出
    prune = { 'node_modules', '.cache', '.local', '.cargo', 'my_huge_dir' },
  },
}
```

**按子仓库正确路由**：每个块里文件的 diff、stage / unstage / discard、冲突 accept 都会落到其**所属仓库**（内部用 `git -C <子仓库根>` + 仓库相对路径），各仓库互不串状态

- **`c` 提交 / `p` push / `P` pull**：作用于**光标所在节点的所属仓库**
- **gitignore 目录默认照扫**：`respect_gitignore=false`（默认）下，被 `.gitignore` 的**目录**仍会被扫描，可手动配置 `respect_gitignore`
- **worktree 默认不当子仓库**：可配置 `scan_worktrees=true`

## Worktree 切换

面板内按 `gw`（或 `:VVGitWorktree`）打开浮窗，列出当前仓库的所有 git worktree：

- **当前所在**的 worktree 以 `●` 标记并高亮，光标默认停在它上面
- 每行显示：分支名（detached 时为 `(detached <短 hash>)`、bare 为 `(bare)`）+ 工作目录路径，失效 / 锁定的 worktree 末尾标 `(prunable)` / `(locked)`
- `<CR>` / `l` 选中 → 面板**切到该 worktree** 看它的 diff，`q` / `<Esc>` 关闭

切换是一次干净的上下文切换：把 `state.git_root` 指向选中的 worktree 并 `tcd` 过去（仅作用于 vv-git 专属 tab，不污染你来时的 tab），随后 reload——之后的 diff / stage / unstage / commit / push 全部落到该 worktree。这是**只读切换器**，不做 `worktree add` / `remove`（按需用 git 命令自行管理）

> worktree 与子仓库是两回事：worktree 是同一份历史的多个 checkout（共享 `.git`），故做成「切过去」而非并排成块；子仓库是独立仓库，并排渲染成块

## 二进制文件拦截

默认开启。预览（光标移动）时静默跳过二进制文件；`<CR>`/`gf` 遇到二进制文件时改用系统默认程序打开，不在 nvim 内尝试渲染乱码 diff

内置扩展名覆盖：图片（png/jpg/gif/webp/heic/…）、视频（mp4/mkv/mov/…）、音频（mp3/wav/flac/…）、压缩包（zip/tar/gz/tgz/jar/deb/dmg/iso/…）、编译产物（exe/dll/so/wasm/bin/…）、字体（ttf/otf/woff/…）、二进制文档（pdf/docx/xlsx/…）、数据库（sqlite/db）

```lua
-- 放行某类扩展名（未来 nvim 支持图片预览时）
opts = {
  binary = {
    extensions = { png = false, jpg = false, jpeg = false },
  },
}

-- 完全关闭拦截
opts = { binary = { intercept = false } }

-- 追加自定义扩展名
opts = { binary = { extensions = { sketch = true, fig = true } } }
```

`binary.extensions` 走 `vim.tbl_deep_extend`，只需写要覆盖的 key，不必重写整张表

## 自定义配色

`highlights` 字段接受任意 `VVGit*` 高亮组的覆盖，叠加在按 Normal 背景自动计算的默认色之上，切换 colorscheme 后依然生效：

```lua
opts = {
  highlights = {
    -- b 侧新增行（整行 / 词级）
    VVGitDiffAdd          = { bg = '#1a3a1a' },
    VVGitDiffChange       = { bg = '#152818' },
    VVGitDiffText         = { bg = '#2a6a2a' },
    -- a 侧对应填充行 / 删除行
    VVGitDiffDeleteDim    = { fg = '#636b78', bg = '#1e1e2e' },
    VVGitDiffAddAsDelete  = { bg = '#4a1a1a' },
    VVGitDiffChangeDelete = { bg = '#2a1010' },
    VVGitDiffTextDelete   = { bg = '#4a1a1a' },
  },
}
```

可覆盖的完整高亮组列表见 `lua/vv-git/hl.lua`

## 快捷键

左栏面板内生效：

| 键 | 说明 |
|------|------|
| `gf` | 跳转到文件 |
| `Y` | 复制文件绝对路径 |
| `<Tab>` | 切换当前文件选中（多选；目录忽略，可配置 `keymap_select`） |
| `<Esc>` | 选中非空时清空选中；否则关闭面板 |
| `j` / `k` / `↓` / `↑` | 跳到下/上一个可选项（`<C-n>`/`<C-p>` 同义；方向键等同 `j`/`k`） |
| `<CR>` / `l` / `→` | 文件：打开 diff；目录/**section 标题**：展开/折叠（`→` 同 `l`） |
| `o` | 系统工具打开：文件→默认程序，目录→文件管理器 |
| `X` | 按文件类型执行：解析运行器后确认，在底部分屏终端运行（仅文件节点） |
| `h` / `←` | 折叠当前节点；子文件折到父目录；**最外层文件 / section 标题**上则折叠整个 section（Staged / Changes / Merge Conflicts）并归位标题行（`←` 同 `h`） |
| `zR` | 焦点留在左侧面板，切换右侧当前 diff 的全部折叠 / 全部展开 |
| `-` | 单选：切换 stage/unstage；**多选**：批量 stage/unstage |
| `d` | 单选—staged: unstage；unstaged: discard（确认）；**多选**：同单选规则批量执行 |
| `c` | 提交（commit） |
| `p` | 推送（push） |
| `P` | 拉取（pull） |
| `u` | 发布当前分支：已有 upstream 时提示使用 `p`；有 `origin` 时直接 `push -u`；只有一个其它 remote 时使用该 remote；多个 remote 时选择；没有 remote 时只输入 URL，自动添加 `origin` 并发布 |
| `<C-e>` | 向下滚动 diff |
| `<C-y>` | 向上滚动 diff |
| `]c` / `[c` | 跳到右侧 diff 的下/上一个 chunk 并居中（在左侧面板即可驱动，无需进入 diff 窗口） |
| `gc` | 查看 commit 本身的 diff：选分支 → 选 commit，展示该 commit 引入的变更（`commit^..commit`） |
| `gw` | Worktree 切换：浮窗列出本仓库所有 worktree，选中即切到该 worktree 看其 diff（`:VVGitWorktree` 等价） |
| `H` | 与 HEAD 比较：选分支 → 选 commit，展示 `commit..HEAD` 的差异 |
| `g?` | 显示帮助 |

提交完成或切换到尚未发布的新分支后，面板会显示 `u  Publish <branch>`。当前分支名由 Git 直接读取，因此不额外询问分支；仅当仓库完全没有 remote 时询问 `origin` URL。也可在面板外执行 `:VVGitPublish`

## 公开接口

### 用户命令

| 分类 | 命令 |
|------|------|
| 面板 | `:VVGit`、`:VVGitClose`、`:VVGitToggle`、`:VVGitTogglePanel`、`:VVGitRefresh` |
| 选择器 | `:VVGitCompare`、`:VVGitCommitShow`、`:VVGitWorktree` |
| Revision | `:VVGitShow <ref>`、`:VVGitCompareRef <ref>`、`:VVGitCompareRefs <from> <to>`、`:VVGitCompareFile <ref>`、`:VVGitCompareStop` |
| Git 操作 | `:VVGitPublish` |
| 配置 / 加载 | `:VVGitSubrepoDepth [n]`、`:VVGitLoad`（仅作为 lazy-load 入口） |

### Lua API

```lua
local git = require('vv-git')

git.setup(opts)
git.config()                         -- 返回配置副本
git.open({ root?, path?, on_ready?, on_error?, on_close? })
git.close()
git.toggle()
git.toggle_panel()
git.refresh()
git.is_open()
git.get_context()

git.show_commit(ref, opts?)
git.compare_with_head(ref, opts?)
git.compare_refs(from_ref, to_ref, opts?)
git.compare_file(ref, opts?)
git.stop_compare()

git.get_subrepo_depth()
git.set_subrepo_depth(n)
git.get_node_path()
git.get_node_dir()
```

`open` 与面板 revision API 的 `opts` 支持：

```lua
{
  root = '/path/to/repo',            -- 仓库或仓库内目录；默认从 cwd 探测
  path = 'src/main.lua',             -- 仓库内相对路径或绝对路径
  on_ready = function(context) end,  -- 面板 / revision 数据就绪
  on_error = function(message) end,
  on_close = function(context) end,  -- 整个 vv-git tab 关闭时触发
}
```

`get_context()` 与回调中的 `context` 是稳定快照，包含 `root`、`path`、`mode`、`layout`、`panel_visible`、`from_ref`、`to_ref`。

`compare_file` 在当前 tab 的原生垂直分屏中对比当前 buffer 或 worktree 文件与指定 ref 中的同一文件，并包含未保存内容。它额外接受 `bufnr`，回调 context 提供 `root`、`path`、`ref`、`bufnr`、`source_win`、`ref_win`。

所有 `_` 开头的字段和方法都是内部实现，不属于公开 API，外部调用方不应依赖。

### 外部事件

每次仓库索引刷新完成后触发：

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'VVGitStatusChanged',
  callback = function(args)
    local root = args.data.root
  end,
})
```

同时**监听** `User VVExplorerRootChanged`（[vv-explorer](https://github.com/beixiyo/vv-explorer.nvim) 切根时广播）。任意文件树都可以发它来让面板跟随：

```lua
vim.api.nvim_exec_autocmds('User', {
  pattern = 'VVExplorerRootChanged',
  data = { root = '/path/to/dir' },
})
```

面板开着时，只有该目录解析出的仓库根与当前不同才切换；面板关着时记住该目录，作为下次 `open()` 的默认根。
