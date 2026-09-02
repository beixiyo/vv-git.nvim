<div align="center">
  <h1>vv-git.nvim</h1>
  <p><a href="./README.md">English</a> | 中文</p>
  <img src="https://github.com/beixiyo/vv-git.nvim/releases/download/assets-2026-07-25/vv-git.png" alt="vv-git 演示" width="900" />
  <img src="https://github.com/beixiyo/vv-git.nvim/releases/download/assets-2026-07-25/vv-git-conflict.png" alt="冲突解决" width="900" />
  <img src="https://github.com/beixiyo/vv-git.nvim/releases/download/assets-2026-07-25/vv-git-help.png" alt="快捷键帮助" width="900" />
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
    parent_repository = 'prompt',      -- cwd 位于祖先仓库内时提示选择（always/never）
    single_col_threshold = 120,        -- 窗口列数 < 此值时降级为单栏 + inline diff
    keymap_toggle_panel = '<leader>b', -- 全局切换左栏的映射（false 禁用）
    keymap_select = '<Tab>',           -- 切换当前文件选中状态（多选）
    keymap_next_file = '<C-j>',        -- diff buffer 内切换到下一个文件（false 禁用）
    keymap_prev_file = '<C-k>',        -- diff buffer 内切换到上一个文件（false 禁用）
    fold_unchanged = true,             -- 折叠未改动代码
    fold_staged = false,               -- 打开面板时默认折叠 Staged Changes section（仅此一层）
    diff_fill = ' ',                   -- diff 空行填充符（Vim 默认 '-'）
    preview = true,                    -- 光标移动到文件行时自动刷新右侧 diff
    directory_preview = true,          -- 光标移动到目录行时显示该目录的变更文件数与状态分布
    inline_diff_max_lines = 10000,     -- 单栏 inline diff 最大行数（超过跳过高亮）
    diff_ratio = { 4, 6 },            -- 双栏 a_win:b_win 宽度比例（不填则 50:50）
    conflict_result_ratio = 0.5,       -- 三栏冲突视图底部 result/worktree 高度比例
  },
}
```

## 配置

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `width` | `integer` | `30` | 左栏宽度；手动调整后跨会话持久化 |
| `state` | `VVStateHandle?` | `nil` | 可选状态容器；默认注册 `vv-git/panel` |
| `parent_repository` | `'prompt' \| 'always' \| 'never'` | `'prompt'` | 隐式打开时如何处理 cwd/explorer 目录之外的祖先仓库；`prompt` 的选择在当前 Neovim 会话中按目录记忆 |
| `single_col_threshold` | `integer` | `120` | 低于此窗口宽度时使用单栏 diff |
| `keymap_toggle_panel` | `string \| false` | `'<leader>b'` | 全局切换左栏；`false` 禁用 |
| `fold_unchanged` | `boolean` | `true` | 默认折叠未改动代码 |
| `fold_staged` | `boolean` | `false` | 打开时折叠父仓库的 Staged Changes |
| `diff_fill` | `string` | `' '` | diff 空行填充符 |
| `preview` | `boolean` | `true` | 移动左栏光标时刷新 diff |
| `directory_preview` | `boolean` | `true` | 预览目录的变更统计；依赖 `preview` |
| `auto_refresh` | `boolean` | `true` | BufEnter / FocusGained 时刷新 Git 状态 |
| `preview_debounce_ms` | `integer` | `150` | 预览防抖毫秒数；`0` 禁用防抖 |
| `inline_diff_max_lines` | `integer` | `10000` | 单栏 inline diff 的最大行数 |
| `right_click` | `string \| false` | `'toggle_stage'` | 右键 action；`false` 禁用 |
| `diff_ratio` | `number[]` | `{ 5, 5 }` | 双栏 a_win:b_win 宽度比例 |
| `conflict_result_ratio` | `number` | `0.5` | 冲突视图 result 窗口高度比例（`0.1`~`0.9`） |
| `diff_nowrap` | `boolean` | `false` | diff 视图强制关闭折行 |
| `highlights` | `table` | `nil` | 覆盖任意 `VVGit*` 高亮组 |
| `before_open` | `fun(): fun()?` | `nil` | 打开前执行；可返回关闭后的恢复函数 |
| `keymap_select` | `string` | `'<Tab>'` | 切换当前行选中状态（多选）；目录节点忽略 |
| `keymap_next_file` | `string \| false` | `'<C-j>'` | diff 中切换到下一个文件 |
| `keymap_prev_file` | `string \| false` | `'<C-k>'` | diff 中切换到上一个文件 |
| `select_move_down` | `boolean` | `true` | 切换选中后下移光标 |
| `mappings` | `table<string, fun(state)>` | `{}` | 新增或覆盖左栏映射 |
| `binary.intercept` | `boolean` | `true` | 拦截二进制文件并使用系统程序打开 |
| `binary.extensions` | `table<string, boolean>` | 内置列表 | 二进制扩展名覆盖；使用合并语义 |
| `subrepo.depth` | `integer` | `0` | 子仓库扫描深度；`0` 禁用 |
| `subrepo.respect_gitignore` | `boolean` | `false` | 发现时是否跳过被父仓库 `.gitignore` 的目录 |
| `subrepo.prune` | `string[]` | 内置列表 | 不扫描的目录名；使用覆盖语义 |
| `subrepo.scan_worktrees` | `boolean` | `false` | 是否将 linked worktree 作为子仓库扫描 |
| `worktree.path` | `fun(root, branch): string` | `<root>/.worktrees/<branch-short>` | 新建 worktree 的路径策略 |

## 配置示例

```lua
opts = {
  subrepo = {
    depth = 1,                  -- 从 cwd 向下扫 1 层找子仓库
    respect_gitignore = false,  -- 默认；HOME-as-repo 必须 false 才看得到 ~/code 等被 ignore 的项目
    -- prune 是数组，覆盖语义：传了就整体替换默认（默认已含 node_modules / .cache /
    -- .local / .cargo 等缓存目录）。想在默认基础上加目录，需把默认项一并列出
    prune = { 'node_modules', '.cache', '.local', '.cargo', 'my_huge_dir' },
  },
  binary = {
    extensions = { png = false, jpg = false, jpeg = false },
  },
  highlights = {
    VVGitDiffAdd = { bg = '#1a3a1a' },
    VVGitDiffAddAsDelete = { bg = '#4a1a1a' },
  },
  worktree = {
    path = function(root, branch)
      return vim.fs.joinpath(root, '.worktrees', branch)
    end,
  },
}
```

`subrepo.prune` 使用覆盖语义；`binary.extensions` 和 `highlights` 使用合并语义

## 插件集成

- `vv-scrollbar.nvim`：普通 diff 显示 staged / unstaged 双轨；冲突视图只在上方右侧 theirs diff 显示单轨 `U`，底部 Result 不重复显示
- `vv-statuscol.nvim`：diff/result 窗口自动隐藏重复的 Git 双轨

## 快捷键

当 `:VVGit` 从不属于任何 Git 仓库的 cwd 打开时，面板会进入初始化空状态。若 cwd 只属于工作区之外的祖先仓库，默认的 `parent_repository='prompt'` 会同时显示 `p` 打开祖先仓库和 `i` 在当前目录初始化；被祖先仓库忽略时默认光标落在 `i`，否则落在 `p`。两项均可用对应快捷键或 `<CR>` 执行，并在同一个 tab 中进入正常仓库视图。选择 `p` 后会按 cwd 记住本次 Neovim 会话，关闭再打开不重复询问；重启 Neovim 后恢复提示。显式传入的无效 `root`/`path` 仍会被拒绝

左栏面板内生效：

| 键 | 说明 |
|------|------|
| `i` | 将当前 cwd 初始化为 Git 仓库（非仓库或祖先仓库决策页） |
| `p` | 打开工作区之外的祖先 Git 仓库（仅在祖先仓库决策页；正常仓库中仍为 push） |
| `gf` | 跳转到文件 |
| `Y` | 复制文件绝对路径 |
| `<Tab>` | 切换当前文件选中（多选；目录忽略，可配置 `keymap_select`） |
| `<Esc>` | 选中非空时清空选中；否则关闭面板 |
| `j` / `k` / `↓` / `↑` | 跳到下/上一个可选项（`<C-n>`/`<C-p>` 同义；方向键等同 `j`/`k`） |
| `<CR>` / `l` / `→` | 决策页：执行当前选项；文件：打开 diff；目录/**section 标题**：展开/折叠（`→` 同 `l`） |
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
| `gw` | Worktree 管理：浮窗内创建、切换、删除和刷新 worktree（`:VVGitWorktree` 等价） |
| `H` | 与 HEAD 比较：选分支 → 选 commit，展示 `commit..HEAD` 的差异 |
| `g?` | 显示帮助 |

右侧 diff 窗口内生效（普通 diff、ours、theirs、Result 都会安装）：

| 键 | 说明 |
|------|------|
| `q` / `<Esc>` | 关闭右侧视图 |
| `gf` | 跳转到文件 |
| `Y` | 复制文件绝对路径 |
| `-` | 切换当前文件 stage/unstage |
| `]c` / `[c` | 跳到下/上一个 chunk 并居中 |
| `<C-j>` / `<C-k>` | 切换到左栏的下/上一个文件（`keymap_next_file` / `keymap_prev_file`） |
| `z*` | 原生折叠命令透传（`za`、`zR`、`zM` 等） |
| `<` / `>` | **冲突视图**：在 Result 窗口按键时接受光标所在的冲突块，光标在块外则先移动到最近的块；在 ours / theirs 窗口按键时接受离 Result 光标最近的块。每次接受都会自动写盘，解决最后一块后自动 `git add` |
| `=` | **冲突视图**：两侧都保留，ours 段在前、theirs 段在后，等价于 `git merge-file --union`。适合两边各自追加了独立内容的冲突；两边改同一条语句时会留下重复行，需要再手工清理 |
| `g?` | 显示当前 buffer 的键位帮助；冲突视图中 Conflict 分类排在最前 |

冲突视图中，左栏的 `<` / `>` 是整文件级接受；三窗右下方 Result 是真实工作区文件，也可以直接编辑后 `:w`。窄屏单栏冲突不提供 hunk 级 `<` / `>`，请使用左栏整文件接受

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
git.get_target_paths()
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
  on_goto_file = function(context) end, -- 可选：接管 gf；省略时关闭 vv-git 并编辑文件
}
```

`get_context()` 与回调返回稳定快照。传入 `on_goto_file` 后，由调用方负责打开文件；`compare_file` 还接受 `bufnr`

所有 `_` 开头的字段和方法都是内部实现，不属于公开 API，外部调用方不应依赖

### 外部事件

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'VVGitStatusChanged',
  callback = function(args)
    local root = args.data.root
  end,
})
```

仓库索引刷新后触发 `User VVGitStatusChanged`。vv-git 也监听 `User VVExplorerRootChanged`：

```lua
vim.api.nvim_exec_autocmds('User', {
  pattern = 'VVExplorerRootChanged',
  data = { root = '/path/to/dir' },
})
```
