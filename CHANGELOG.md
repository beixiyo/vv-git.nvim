# Changelog

## Unreleased

### Added

- Added `<Esc>` mapping to close the panel and diff view.
- **窄终端单栏 fallback**：窗口列数 < `single_col_threshold` 时不再拒绝打开 / 关闭 tab，自动降级为「panel + 单栏 b 视图」，列数恢复后自动升回 dual diff
- **单栏 inline diff 高亮**：单栏模式下用 `vim.diff()` 在 b_buf 上叠 extmark，新增/修改行整行染色 + 删除行通过 `virt_lines` 在原位上方显示，覆盖 staged 和 unstaged
- **字符级 word-diff 高亮**：单栏 inline 模式下 rc==ac 改动行（含 a 侧 virt_lines）按字符级 `vim.diff` 拆 chunk，改动字符显深色 / 上下文显浅色，仿 gitsigns `lua/gitsigns/diff_int.lua`（`split_chars` + `denoise_hunks` + 1:1 行配对，`DENOISE_GAP=5` 避免破碎闪烁）。注意按 byte 切，CJK 多字节文件可能切到字符中间，ASCII 主导文件无影响
- **双栏 `inline:char`**：`vim.opt.diffopt` 追加 `inline:char`（nvim 0.11+），双栏模式下 `DiffText` / `DiffTextAdd` 由 nvim 内置字符级 diff 驱动，不再"首字差异 → 末字差异"整段染色
- 新增高亮组 `VVGitDiffTextAdd` / `VVGitDiffTextAddDelete`（nvim 0.11+ `inline:char/word` 配套：标"对侧无对应原文"的纯增/删字符），`WINHL_A` / `WINHL_B` 同步映射避免 fall-through 到全局默认色
- **单栏自动折叠**：仿 dual mode `foldmethod=diff`，未改动行 ±6 行上下文外自动折叠（`foldmethod=manual`）；与 nvim-ufo 通过 detach/attach 协作避免冲突
- **自动跳到第一处变更**：dual / single 两种模式打开文件时光标直接落在第一个 hunk 上 + `zz` 居中
- **单栏 worktree 实时刷新**：unstaged 单栏的 worktree b_buf 上挂 `TextChanged` 200ms 去抖，编辑后 inline diff 跟着 hunks 重算
- 配置项 `inline_diff_max_lines`（默认 10000）：超过此行数跳过 inline 渲染，避免大文件 vim.diff 卡顿

### Changed

- `single_col_threshold` 语义：从「< 此值时拒绝打开 / 关 tab」改为「< 此值时降级为单栏」；保留配置名但语义升级
- `M.open` 入口取消「窄屏拒绝」分支：现在任何宽度都能打开
- `_apply_layout` 加 50ms 去抖：拖拽 resize 不再每帧触发 git show + vim.diff
- staged 单栏 inline 模式两次 `git show` 改并发 + barrier 合流（仿 `render_dual_rev_rev`），快速 j/k 切文件每次省 5-50ms
- **配色重构为两级 + 字符高亮三层**：`VVGitDiffAdd` / `VVGitDiffAddAsDelete` 改指**纯增 / 纯删整行的深色**，`VVGitDiffChange` / `VVGitDiffChangeDelete` 指**改动行上下文的浅色**，`VVGitDiffText` / `VVGitDiffTextDelete` 在浅色之上叠深色字符。alpha 改用 vsc-theme (beixiyo/vsc-theme) 原版 0x21/0x55 + 0x22 叠加（之前 0x99/0xaa 实测过饱和浮夸）
- hl.lua 用前缀匹配 `^VVGitDiff` 区分"权威覆盖"与"用户可主题化"两类色组，替代手写 `DIFF_OWN` 白名单——新增 diff 色组不必再两处同步，避免回归到 `default=true` 的缓存陷阱

### Fixed

- 修复 `p` (push) 成功后，左侧面板未自动刷新导致未推送 commit 数量没更新的问题
- 修复 `s` (切换暂存状态) 和 `o` (打开文件) 快捷键被意外添加到 `<Nop>` 禁用列表导致无法使用的问题
- **diff 视图 zR/zM 折叠 snap-back**：用户全局 `zR`/`zM` 映射到 nvim-ufo 时，ufo 的 `:%foldopen!` 不动 `foldlevel`，TTY 重绘 / 第三方插件 `WinScrolled` 回调会让所有折叠瞬间塌回去。在 a_buf / b_buf 上 buffer-local 包装全部 18 个 fold 命令为 `vim.cmd("normal! ...")`，用 `:normal!` 绕过用户映射跑 vanilla 实现
- **修复缺失字符级 diff**：双栏 / 单栏两条路径之前都没接入 nvim 0.11+ `inline:char` + `DiffTextAdd` + word-diff 算法，"改动行" 看起来是整段同色，与 VSCode / gitsigns 的视觉脱节。本次补齐两条路径的字符级渲染管线
- **修复单栏删除侧上下文与改动字符塌成同色**：a 侧 word-diff 上下文之前误用 `VVGitDiffAddAsDelete`（在新两级配色下已是深红），与"改动字符也深红"无差别。改用 `VVGitDiffChangeDelete`（浅红），与 b 侧 `VVGitDiffChange` + `VVGitDiffText` 的"浅 + 深"层次对称

## 0.1.0 (2026-04-25)

- 首个公开版本：VSCode 风 git diff 双栏视图（panel + a_win + b_win，专属 tabpage 隔离）
