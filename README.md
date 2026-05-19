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
| `highlights` | `table` | 无 | 覆盖任意 `VVGit*` 高亮组，叠加在自动计算值之上，切换主题后仍生效（见下方「自定义配色」）|


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
| `<Tab>` | 展开 / 折叠目录 |
| `h` | 折叠当前节点 |
| `-` | 切换 stage / unstage |
| `d` | staged 区：unstage；unstaged 区：撤销更改（discard），确认后生效 |
| `c` | 提交（commit） |
| `p` | 推送（push） |
| `P` | 拉取（pull） |
| `<C-e>` | 向下滚动 diff |
| `<C-y>` | 向上滚动 diff |
| `g?` | 显示帮助 |
