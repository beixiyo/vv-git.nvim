<h1 align="center">vv-git.nvim</h1>

<p align="center">
  <em>VSCode 风格 git diff 双栏视图 — 专属 tab 隔离、自动折叠未改动代码</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
  <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
</p>

---

## 安装

```lua
{
  'beixiyo/vv-git.nvim',
  dependencies = { 'beixiyo/vv-utils.nvim' },
  cmd = { 'VVGit', 'VVGitToggle', 'VVGitClose' },
  keys = { '<leader>b' },
  ---@type VVGitConfig
  opts = {
    width = 30,                        -- 左栏宽度
    single_col_threshold = 120,        -- 窗口列数 < 此值时降级为单栏 + inline diff
    keymap_toggle_panel = '<leader>b', -- 全局切换左栏的映射（false 禁用）
    keymap_select = '<Tab>',           -- 切换当前文件选中状态（多选）
    fold_unchanged = true,             -- 折叠未改动代码
    diff_fill = ' ',                   -- diff 空行填充符（Vim 默认 '-'）
    preview = true,                    -- 光标移动到文件行时自动刷新右侧 diff
    inline_diff_max_lines = 10000,     -- 单栏 inline diff 最大行数（超过跳过高亮）
    diff_ratio = { 4, 6 },            -- 双栏 a_win:b_win 宽度比例（不填则 50:50）
  },
}
```

## 配置

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `width` | `integer` | `30` | 左栏宽度（字符数） |
| `single_col_threshold` | `integer` | `120` | 窗口列数低于此值时降级为单栏（仅 b 侧 + inline diff），≥ 此值双栏；resize 自动迁移 |
| `keymap_toggle_panel` | `string \| false` | `'<leader>b'` | 全局切换左栏可见性的映射；`false` 禁用 |
| `fold_unchanged` | `boolean` | `true` | 未改动代码是否默认折叠（dual: `foldmethod=diff`；single: manual fold） |
| `diff_fill` | `string` | `' '` | diff 空行填充符，映射到 `fillchars` 的 `diff:X` |
| `preview` | `boolean` | `true` | 光标在左栏移动时自动刷新右侧 diff，无需手动 `<CR>` |
| `inline_diff_max_lines` | `integer` | `10000` | 单栏模式下 `vim.diff` 最大支持行数，超过只显示文本不画高亮 |
| `right_click` | `string \| false` | `'toggle_stage'` | 右键触发的 action 名（如 `'yank_abs_path'`），`false` 禁用 |
| `diff_ratio` | `integer[]` | 无（50:50） | 双栏模式下 a_win（旧版本）与 b_win（工作区）的宽度比例，如 `{4, 6}` 表示左窄右宽；不填则等宽 |
| `diff_nowrap` | `boolean` | `true` | diff 视图强制关闭折行；`wrap` 在双栏模式下因两侧行高不一致会造成视觉错位，属于上游已知限制（[neovim/neovim#29518](https://github.com/neovim/neovim/issues/29518)、[diffview.nvim#198](https://github.com/sindrets/diffview.nvim/issues/198)），置为 `false` 可恢复默认折行行为 |
| `highlights` | `table` | 无 | 覆盖任意 `VVGit*` 高亮组，叠加在自动计算值之上，切换主题后仍生效（见下方「自定义配色」）|
| `keymap_select` | `string` | `'<Tab>'` | 切换当前行选中状态（多选）；目录节点忽略 |
| `select_move_down` | `boolean` | `false` | `<Tab>` 切换选中后自动将光标下移一行 |
| `binary.intercept` | `boolean` | `true` | 拦截二进制文件：预览时静默跳过，`<CR>`/`gf` 改用系统默认程序打开；`false` 禁用拦截 |
| `binary.extensions` | `table<string, boolean>` | 见下方 | 视为二进制的扩展名集合（小写 key）；`vim.tbl_deep_extend` 合并，只需写要覆盖的 key |


## 二进制文件拦截

默认开启。预览（光标移动）时静默跳过二进制文件；`<CR>`/`o`/`gf` 遇到二进制文件时改用系统默认程序打开，不在 nvim 内尝试渲染乱码 diff。

内置扩展名覆盖：图片（png/jpg/gif/webp/heic/…）、视频（mp4/mkv/mov/…）、音频（mp3/wav/flac/…）、压缩包（zip/tar/gz/tgz/jar/deb/dmg/iso/…）、编译产物（exe/dll/so/wasm/bin/…）、字体（ttf/otf/woff/…）、二进制文档（pdf/docx/xlsx/…）、数据库（sqlite/db）。

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

`binary.extensions` 走 `vim.tbl_deep_extend`，只需写要覆盖的 key，不必重写整张表。

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

可覆盖的完整高亮组列表见 `lua/vv-git/hl.lua`。

## 快捷键

左栏面板内生效：

| 键 | 说明 |
|------|------|
| `gf` | 跳转到文件 |
| `Y` | 复制文件绝对路径 |
| `<Tab>` | 切换当前文件选中（多选；目录忽略，可配置 `keymap_select`） |
| `<Esc>` | 选中非空时清空选中；否则关闭面板 |
| `<CR>` / `o` / `l` | 文件：打开 diff；目录/**section 标题**：展开/折叠 |
| `h` | 折叠当前节点；光标在 **section 标题**（Staged / Changes / Merge Conflicts）上时折叠整个 section |
| `-` | 单选：切换 stage/unstage；**多选**：批量 stage/unstage |
| `d` | 单选—staged: unstage；unstaged: discard（确认）；**多选**：同单选规则批量执行 |
| `c` | 提交（commit） |
| `p` | 推送（push） |
| `P` | 拉取（pull） |
| `<C-e>` | 向下滚动 diff |
| `<C-y>` | 向上滚动 diff |
| `gc` | 查看 commit 本身的 diff：选分支 → 选 commit，展示该 commit 引入的变更（`commit^..commit`） |
| `H` | 与 HEAD 比较：选分支 → 选 commit，展示 `commit..HEAD` 的差异 |
| `g?` | 显示帮助 |
