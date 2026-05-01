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
