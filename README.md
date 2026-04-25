# vv-git.nvim

VSCode 风格 git diff 双栏视图，无外部依赖（除 [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim)）

## 安装

lazy.nvim：

```lua
{
  'beixiyo/vv-git.nvim',
  dependencies = { 'beixiyo/vv-utils.nvim' },
  cmd = { 'VVGit', 'VVGitToggle', 'VVGitClose' },
  keys = { '<leader>b' },
  opts = {},
}
```

## 依赖

| 插件 | 必选 | 说明 |
|------|------|------|
| `vv-utils.nvim` | 是 | 通用工具库 |
| `mini.icons` | 否 | 文件图标，缺失时 fallback 到纯字符 |

**架构**：打开时 `:tab split` 创建**专属 tabpage**，panel + a_win + b_win 全在里面。避免与用户当前 tab 的其它窗口（bufferline、scrollview、render-markdown preview、gitsigns diffthis 等）共享同一个 diff-group，防止"通体红绿"污染。关闭时整个 tab `tabclose`，回跳原 tab。

## 配置

```lua
require('vv-git').setup({
  width = 30,                       -- 左栏宽度
  single_col_threshold = 120,       -- 窗口宽度 < 此值时隐藏左栏 + a_win，只留 b_win
  keymap_toggle_panel = '<leader>b', -- 全局切换左栏的 normal 映射；false 禁用
  fold_unchanged = true,             -- diff 视图默认折叠未改动代码
  diff_fill = ' ',                   -- diff 空行填充符（Vim 默认 '-'）
  preview = true,                    -- panel 中光标移动到文件行时自动刷新右侧 diff
})
```

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `width` | `integer` | `30` | 左栏宽度（字符数） |
| `single_col_threshold` | `integer` | `120` | 窗口列数低于此值时自动降级为单栏模式 |
| `keymap_toggle_panel` | `string\|false` | `'<leader>b'` | 全局切换左栏可见性的 Normal 映射；设为 `false` 禁用 |
| `fold_unchanged` | `boolean` | `true` | diff 视图中未改动代码是否默认折叠 |
| `diff_fill` | `string` | `' '` | diff 空行填充符，映射到 `fillchars` 的 `diff:X` |
| `preview` | `boolean` | `true` | 光标在左栏移动到文件行时自动刷新右侧 diff，无需手动 `<CR>` |

## 功能

- 左栏：commit 浮窗 + 变更文件树（staged / unstaged 两 section，支持文件夹折叠）
- 右栏：双栏 diff（宽度 ≥ 阈值）/ 单栏（< 阈值自动隐藏左栏）
- 文件夹级 stage/unstage 递归操作
- 右侧 b 窗口可编辑，`:w` 后重算 diff 刷新树
- 新增文件走单栏（无对比源）
- 冲突文件跳过（提示用户手动解决）

## 命令

| 命令 | 说明 |
|------|------|
| `:VVGit`         | 打开 |
| `:VVGitClose`    | 关闭 |
| `:VVGitToggle`   | 切换 |
| `:VVGitTogglePanel` | 切换左栏可见性（不关闭整个 vv-git tab） |
| `:VVGitRefresh`  | 重跑 git status |

## 左栏按键

| 键 | 行为 |
|----|------|
| `<CR>` / `l` / `o` / `<2-LeftMouse>` | 打开 diff |
| `gf`       | 脱离 diff 视图，在原主窗口普通打开该文件 |
| `h`        | 折叠 / 收起当前 |
| `<Tab>`    | 折叠当前目录 |
| `s`        | Stage ↔ Unstage（按当前 section 自动 toggle，文件 / 文件夹递归） |
| `X`        | Discard |
| `c`        | Commit（有 staged → 提交 staged；无 staged → 先确认再整仓提交） |
| `p`        | Push |
| `P`        | Pull（成功后自动刷新） |
| `R`        | 刷新 |
| `q`        | 关闭 |
| `<C-e>`    | 在左栏中向下滚动右侧 diff（步长 5 行） |
| `<C-y>`    | 在左栏中向上滚动右侧 diff（步长 5 行） |
| `g?`       | 帮助浮窗 |

## 提交浮窗按键

| 键 | 行为 |
|----|------|
| `<C-s>`（n/i）| 执行提交（无 staged 时自动 `git add -A`） |
| `<Esc>` / `q`（n） | 取消 |

## 架构

```
lua/vv-git/
├── init.lua         # setup / 命令 / 全局 autocmd / 专属 tab 生命周期
├── state.lua        # 单例状态（包含 tabpage / prev_tab）
├── hl.lua           # 高亮组 + alpha 混色（ColorScheme 自动重算）
├── git.lua          # index / show / stage / unstage / discard / commit
├── tree.lua         # 虚拟文件树（basename trie）+ flatten + 递归 leaf 收集
├── icons.lua        # MiniIcons 包装（无则 fallback 字符）
├── help.lua         # g? 帮助浮窗
├── left/
│   ├── panel.lua    # 左栏窗口生命周期（vsplit + bufhidden=hide）
│   ├── render.lua   # 两 section + 文件夹折叠渲染
│   ├── actions.lua  # stage / unstage / discard 动作
│   └── prompt.lua   # commit 浮窗（filetype=gitcommit）
└── right/
    └── view.lua     # a | b 双栏 diff，新增文件降级单栏
```

## 技术要点

- **专属 tabpage 隔离**：全部窗口在独占 tab 内创建，diff-group 天然只含 a_win/b_win，任何第三方插件（bufferline buffers、nvim-scrollview workspace window、render-markdown preview、gitsigns diffthis）都不会污染我们的对比
- **差异算法**：不自己算，依赖 Neovim 原生 diff-mode（`vim.wo.diff=true` + `scrollbind/cursorbind` + `diffopt:linematch:60`）
- **双侧异色**：同一 `DiffAdd`，左窗口 `winhighlight` link 到 `VVGitDiffAddAsDelete`（红），右窗口 link 到 `VVGitDiffAdd`（绿）
- **alpha 混色**：Neovim 原生高亮无 alpha 通道，用 `over 合成`手动把 `#RRGGBBAA` 叠到 `Normal.bg` 上
- **虚拟树**：不扫文件系统，只把 `git status --porcelain=v1 -z` 的相对路径插入 trie；单链目录 `group_empty_dirs` 合并显示
- **窄屏降级**：窗口宽度 < 阈值时自动关 panel + a-win，只留 b-win（普通编辑），`VimResized` 监听恢复

## Testing

Smoke test (zero deps, runs in `-u NONE`):

```bash
nvim --headless -u NONE -l tests/test_smoke.lua
```

Expected: trailing line `X passed, 0 failed`.
