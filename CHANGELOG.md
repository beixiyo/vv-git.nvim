# Changelog

## Unreleased

### Added

- Added `<Esc>` mapping to close the panel and diff view.
- **窄终端单栏 fallback**：窗口列数 < `single_col_threshold` 时不再拒绝打开 / 关闭 tab，自动降级为「panel + 单栏 b 视图」，列数恢复后自动升回 dual diff
- **单栏 inline diff 高亮**：单栏模式下用 `vim.diff()` 在 b_buf 上叠 extmark，新增/修改行整行染色 + 删除行通过 `virt_lines` 在原位上方显示，覆盖 staged 和 unstaged
- **单栏自动折叠**：仿 dual mode `foldmethod=diff`，未改动行 ±6 行上下文外自动折叠（`foldmethod=manual`）；与 nvim-ufo 通过 detach/attach 协作避免冲突
- **自动跳到第一处变更**：dual / single 两种模式打开文件时光标直接落在第一个 hunk 上 + `zz` 居中
- **单栏 worktree 实时刷新**：unstaged 单栏的 worktree b_buf 上挂 `TextChanged` 200ms 去抖，编辑后 inline diff 跟着 hunks 重算
- 配置项 `inline_diff_max_lines`（默认 10000）：超过此行数跳过 inline 渲染，避免大文件 vim.diff 卡顿

### Changed

- `single_col_threshold` 语义：从「< 此值时拒绝打开 / 关 tab」改为「< 此值时降级为单栏」；保留配置名但语义升级
- `M.open` 入口取消「窄屏拒绝」分支：现在任何宽度都能打开
- `_apply_layout` 加 50ms 去抖：拖拽 resize 不再每帧触发 git show + vim.diff
- staged 单栏 inline 模式两次 `git show` 改并发 + barrier 合流（仿 `render_dual_rev_rev`），快速 j/k 切文件每次省 5-50ms

### Fixed

- 修复 `p` (push) 成功后，左侧面板未自动刷新导致未推送 commit 数量没更新的问题
- 修复 `s` (切换暂存状态) 和 `o` (打开文件) 快捷键被意外添加到 `<Nop>` 禁用列表导致无法使用的问题
- **diff 视图 zR/zM 折叠 snap-back**：用户全局 `zR`/`zM` 映射到 nvim-ufo 时，ufo 的 `:%foldopen!` 不动 `foldlevel`，TTY 重绘 / 第三方插件 `WinScrolled` 回调会让所有折叠瞬间塌回去。在 a_buf / b_buf 上 buffer-local 包装全部 18 个 fold 命令为 `vim.cmd("normal! ...")`，用 `:normal!` 绕过用户映射跑 vanilla 实现

## 0.1.0 (2026-04-25)

- 首个公开版本：VSCode 风 git diff 双栏视图（panel + a_win + b_win，专属 tabpage 隔离）
