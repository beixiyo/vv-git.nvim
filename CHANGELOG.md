# Changelog

## Unreleased

### Added

- **左侧面板驱动 chunk 跳转**：在文件树面板里直接按 `]c` / `[c` 跳到右侧 diff 的下/上一个 chunk，无需先进入 diff 窗口。`]c`/`[c` 是原生 diff-mode 动作、只在 `diff=true` 的窗口有意义，故复用 `scroll_diff` 的锚点逻辑（取 a/b 中行数最多的窗口）+ `nvim_win_call` 把动作放到 diff 窗口上下文执行（`]czz`/`[czz` 跳完即居中，scrollbind 带动另一侧同步），焦点仍留在面板，与 `<C-e>`/`<C-y>` 滚动一致

- **子仓库扫描**：新增 `subrepo.depth`（默认 `0` 不扫描）；每个子仓库作为独立可折叠块，标题行显示其相对路径 + 当前分支（` 󰘬 <branch>`），diff / stage / unstage / discard / 冲突 accept / commit / push 全按所属仓库路由

- **Worktree 切换**（`gw` / `:VVGitWorktree`）：浮窗列出当前仓库的所有 git worktree（标记当前所在、显示分支 / detached / locked / prunable）

- **worktree 不当子仓库**：子仓库扫描默认跳过 linked worktree

- **分支显示**：左栏根仓库与各子仓库标题行均在最前显示当前分支（彩色分支图标 + 分支名，detached 时为短 hash）

- **根仓库可折叠**：根仓库标题行带折叠箭头，`l`/`h`/单击折叠后隐藏其 commit 提示与三个 section（子仓库块不受影响），与子仓库块共用同一套折叠交互
 
- **方向键导航**：面板内 `↑/↓` 同 `j`/`k`（跳上/下一个可选项）、`→` 同 `l`（展开/激活）、`←` 同 `h`（折叠），照顾习惯方向键的用户
 
- **状态变更广播**：任意 git 变更（stage/unstage/discard/commit/push/conflict）完成后，`reload_index` 发一个 `User VVGitStatusChanged` 事件（`data.root` 带仓库根），供 vv-explorer / vv-statuscol 等外部消费者即时刷新自身 git 索引，无需轮询或等 `FocusGained`

- **预览防抖**：`preview_debounce_ms` 光标停顿后才刷新右侧 diff，避免快速 `j`/`k` 时频繁重算；`0` = 不防抖（同步直刷）

- **Section 折叠**：`Staged Changes` / `Changes` / `Merge Conflicts` 标题行现在带折叠箭头，光标在标题上时 `<CR>`/`o`/`l` 切换展开/折叠、`h` 直接折叠、单击（`<LeftRelease>`）也可切换；折叠后只保留标题行，文件列表隐藏。折叠状态按 section 独立记录（`state.section_folds`），折叠/展开后光标固定在标题行不跳走

- **查看 commit diff**（`gc`）：选分支 → 选 commit，展示该 commit 本身引入的变更（`commit^..commit`），即这次提交改了什么。初始 commit（无父节点）自动用 empty-tree 兜底。

- **与 HEAD 比较**（`H`）：选分支 → 选 commit，展示该 commit 与当前 HEAD 之间的差异（`commit..HEAD`），即"从那时到现在改了什么"。

  两种模式共用同一套左栏文件列表 + 右侧双栏 diff 基础设施；`<Esc>` 退出，左栏立即恢复正常视图。

- **Compare 模式树结构**：`H`/`gc` 的变更文件列表从扁平路径改为树形目录结构，与 normal 模式的 Staged/Changes 视图一致——支持目录折叠箭头、文件类型图标、单链目录合并（`src/foo/bar/` 显示为一行）、`l`/`h` 展开/折叠

- **多选操作**：`<Tab>`（可配置 `keymap_select`）切换当前文件的选中状态，选中行以 `VVGitPanelSelected` 高亮标记；选中集合非空时，`-`/`d` 批量操作所有选中文件（staged → unstage，unstaged → stage/discard，两侧可混合）；`<Esc>` 优先清空选中，无选中时关闭面板；`v`/`V`/`<C-v>` 已屏蔽（nofile buffer 里 visual 模式无意义）

- **二进制文件拦截**：`binary.intercept = true`（默认开启），预览时静默跳过，`<CR>`/`o`/`gf` 遇到二进制文件改用系统默认程序打开，避免渲染乱码 diff 造成卡顿。内置 40+ 扩展名（图片/视频/音频/压缩包/编译产物/字体/二进制文档/数据库），支持 `binary.extensions` 逐 key 增减覆盖

- **左侧填充行背景色**：双栏模式下，左侧（a 面）对应右侧纯新增行的填充空行现在显示浅绿背景（`VVGitDiffDeleteDim.bg = add_line`），与右侧绿色新增行视觉对称，不再显示为空白

- **`highlights` 自定义配色**：`setup()` 的 `opts` 新增 `highlights` 字段，可覆盖任意 `VVGit*` 高亮组；用户提供的 spec 叠加在按 Normal 背景自动计算的默认色之上，`ColorScheme` 切换主题后仍持续生效

- **gitsigns 协同刷新**：监听 `User GitSignsChanged` 事件，在右侧 diff 预览中通过 gitsigns 暂存/取消暂存 hunk 后，左栏文件列表和右侧 diff 自动刷新，焦点保持在原窗口不跳转

- **智能定位当前文件**：按 `<leader>gd` 打开或切换到 Git 面板时，若当前 buffer 有改动，会自动将光标定位到该文件并展示 diff；若目标路径在折叠的目录中，会自动展开父目录
 
- **文件夹状态图标**：Git 面板中的目录图标现在支持“展开”与“收起”状态切换，视觉表现与 `vv-explorer` 及 `snacks.nvim` 完全同步
 
- **鼠标操作**：单击（`<LeftRelease>`）展开/收起目录；右键（`<RightMouse>` + `getmousepos()`）执行可配置 action（默认 `toggle_stage`），屏蔽右键 visual 选区（含双击/三击）。配置项 `right_click`（`string|false`）
 
- **鼠标 visual 屏蔽**：屏蔽 `<LeftDrag>`（左键拖拽）和 `<2-LeftMouse>`（双击左键），防止鼠标操作触发 visual 选区
 
- **j/k 循环导航**：`j`/`k`/`<C-n>`/`<C-p>` 在可交互行间跳转，到边缘自动循环回绕，跳过空行和非交互行
 
- **默认光标在 Changes**：初次渲染时光标优先定位到 Changes（unstaged）区域的第一个文件，而非 Staged Changes；当前文件同时存在于 Staged 与 Changes 时，也优先落在 Changes 一侧
 
- Added `<Esc>` mapping to close the panel and diff view.
 
- **窄终端单栏 fallback**：窗口列数 < `single_col_threshold` 时不再拒绝打开 / 关闭 tab，自动降级为「panel + 单栏 b 视图」，列数恢复后自动升回 dual diff
 
- **单栏 inline diff 高亮**：单栏模式下用 `vim.diff()` 在 b_buf 上叠 extmark，新增/修改行整行染色 + 删除行通过 `virt_lines` 在原位上方显示，覆盖 staged 和 unstaged
 
- **字符级 word-diff 高亮**：单栏 inline 模式下 rc==ac 改动行（含 a 侧 virt_lines）按字符级 `vim.diff` 拆 chunk，改动字符显深色 / 上下文显浅色，仿 gitsigns `lua/gitsigns/diff_int.lua`（`split_chars` + `denoise_hunks` + 1:1 行配对，`DENOISE_GAP=5` 避免破碎闪烁）。注意按 byte 切，CJK 多字节文件可能切到字符中间，ASCII 主导文件无影响
 
- **双栏 `inline:char`**：`vim.opt.diffopt` 追加 `inline:char`（nvim 0.11+），双栏模式下 `DiffText` / `DiffTextAdd` 由 nvim 内置字符级 diff 驱动，不再"首字差异 → 末字差异"整段染色
 
- 新增高亮组 `VVGitDiffTextAdd` / `VVGitDiffTextAddDelete`（nvim 0.11+ `inline:char/word` 配套：标"对侧无对应原文"的纯增/删字符），`WINHL_A` / `WINHL_B` 同步映射避免 fall-through 到全局默认色
 
- **单栏自动折叠**：仿 dual mode `foldmethod=diff`，未改动行 ±6 行上下文外自动折叠（`foldmethod=manual`）；与 nvim-ufo 通过 detach/attach 协作避免冲突
 
- **自动跳到第一处变更**：dual / single 两种模式打开文件时光标直接落在第一个 hunk 上 + `zz` 居中
 
- 配置项 `inline_diff_max_lines`（默认 10000）：超过此行数跳过 inline 渲染，避免大文件 vim.diff 卡顿

- **Panel 宽度持久化**：调整左栏宽度后跨 session 记住，通过 `WinResized` 实时跟踪 + `VimLeavePre` / `M.close` 写入 `stdpath('data')/vv-git.json`
- **Panel 防 V 模式**：`open_split` 立即清除从 diff 窗口继承的 `diff`/`scrollbind`/`cursorbind`，屏蔽 panel buffer 的 `v`/`V`/`<C-v>`

### Changed

- **文件夹行不再显示 git 状态**：左栏文件树中，目录行不再聚合显示子文件中最严重的状态字母（`M`/`A`/`D`/`?` 等），仅文件 leaf 行保留状态字母；normal 与 compare 两种模式一致
- **`h` / `←` 在最外层文件上折叠整个 section**：此前最外层文件（无父目录可收）按 `h` 无反应；现继续往外折叠其所属 section（Staged Changes / Changes / Merge Conflicts）并把光标归到该 section 标题行，与 yazi/资源管理器「向左一路收起」的直觉一致
- **`d` 键 staged 区行为改为 unstage**：与 VSCode 对齐——staged 区按 `d` 只做 unstage，不再同时 discard；unstaged 区保持原有 discard + 确认弹窗逻辑不变

- **图标系统重构**：`icons.lua` 现已接入 `vv-icons` 增强接口，支持 `open` 和 `empty` 状态传递
- **兼容性增强**：在支持增强图标的同时，保留了对 `_G.MiniIcons` 全局标准接口的探测与回退逻辑
- `single_col_threshold` 语义：从「< 此值时拒绝打开 / 关 tab」改为「< 此值时降级为单栏」；保留配置名但语义升级
- `M.open` 入口取消「窄屏拒绝」分支：现在任何宽度都能打开
- `_apply_layout` 加 50ms 去抖：拖拽 resize 不再每帧触发 git show + vim.diff
- staged 单栏 inline 模式两次 `git show` 改并发 + barrier 合流（仿 `render_dual_rev_rev`），快速 j/k 切文件每次省 5-50ms
- **配色重构为两级 + 字符高亮三层**：`VVGitDiffAdd` / `VVGitDiffAddAsDelete` 改指**纯增 / 纯删整行的深色**，`VVGitDiffChange` / `VVGitDiffChangeDelete` 指**改动行上下文的浅色**，`VVGitDiffText` / `VVGitDiffTextDelete` 在浅色之上叠深色字符。alpha 改用 vsc-theme (beixiyo/vsc-theme) 原版 0x21/0x55 + 0x22 叠加（之前 0x99/0xaa 实测过饱和浮夸）
- hl.lua 用前缀匹配 `^VVGitDiff` 区分"权威覆盖"与"用户可主题化"两类色组，替代手写 `DIFF_OWN` 白名单——新增 diff 色组不必再两处同步，避免回归到 `default=true` 的缓存陷阱

### Fixed

- **面板内 `j`/`k` 导航光标不再上下拉扯**：`auto_refresh`（`ea55f15` 引入）的 `BufEnter` 触发在纯 `j`/`k` 导航期会被 preview 的 `nvim_win_set_buf`（同一 tab 内对 a/b diff 窗各切一次 buffer，对非当前窗口也发 `BufEnter`）反复点起 200ms 防抖 `refresh` → `reload_index` → `render`，`render` 末尾按「防抖 preview 滞后约 150ms 的 `cur_path`」把光标硬拉回旧行，跳动又自触发 `CursorMoved` 形成自激回环（停不下来、来回抖）。改在**渲染层**根治、不动触发器（保留 `BufEnter` 的灵敏刷新）：所有经 `M.refresh` 的被动刷新（`auto_refresh` / 保存 / gitsigns / 手动 `R` / commit-push）现在走 `passive` 渲染——`render` 在重写 buffer **之前**先记下「光标此刻在哪个文件」，渲染后把光标放回该文件（内容变了就跟它到新行、找不到再按原行号 clamp），完全不读滞后的 `cur_path`、也不管焦点在不在 panel，使刷新对光标成为 no-op，断掉回环。带 `_action_hint`/`_section_hint` 的动作（stage 落点 afc82c2 / fold / 多选）不是 passive，落点逻辑不受影响；「点进面板/外部变化自动刷新」保持原灵敏度
- **`<leader>b` 隐藏面板不再误关整个 tab**：未打开任何 diff（`state.view == nil`）时按 `<leader>b` 隐藏面板，因先关窗后置空导致同步 `WinClosed` handler 误判不变式而 tabclose 整个 vv-git tab。改为先 `state.panel.win = nil` 再关窗，让 handler 短路，恢复「隐藏后可再按一次重新展开」
- **多选 accept ours/theirs 生效**：`<` / `>` 多选冲突文件后此前因缺 `accept_ours_selection` / `accept_theirs_selection` 处理器而静默清空选择且什么都不做；补上批量处理器（仅作用于 conflicts 区选中项），并加固 `_action` 仅在确实存在处理器时才清空选择
- **inline diff cleanup 后不再被滞后回调重绘**：切文件 / 关 view 时若已有一个 200ms 去抖回调入队，`cancel()` 无法撤回，仍会把 extmark/fold 重新画回已离开 view 的 worktree buffer。新增 `cancelled` 标志让这种滞后回调彻底变成 no-op
- **reshow 焦点目标不再跨 preview 泄漏**：reshow 的异步 git show 被更新的 preview 超越时，`_reshow_restore_win` 此前不会被清，导致下一次普通 preview 把焦点错误地还给旧 diff 窗口。改为把该全局与当次 `req_id` 绑定，仅持有者可消费，并在成功消费 / 被超越时统一清理
- **大文件双栏 diff 不再卡顿**：`schedule_diff_sync` 仅为定位首个 hunk 光标行却跑了一遍全量 myers+linematch diff，且无行数上限。补上与 inline 单栏一致的 `inline_diff_max_lines` 上限，超限直接跳过、光标停在当前行（原生 diff-mode 高亮/折叠不受影响）
- **在途 commit 回调不再误关重开的提交浮窗**：提交在途时再开新提交浮窗，旧提交成功回调此前无条件 `close()` 会把刚开的新浮窗关掉。改为在 submit 时快照 prompt 身份（`owner = cur`），仅 `cur == owner` 时才 close / 复位 submitting
- **多选 discard / stage 与所见一致**：选择键跨渲染持久化，外部 git 变更（如 `git add` 把 `??` 文件移入 staged）重建树后旧键仍残留，导致 untracked 文件被误分类为 tracked 路由到 `git restore`（no-op）、确认框漏掉删除警告。`reload_index` 重建树后剪枝掉在新树对应分区已不存在的选择键
- **diff 滚动锚点智能选择**：`<C-e>`/`<C-y>` 滚动 diff 时固定驱动 `b_win`（新/after 侧），大批量**删除**时 b_win 内容很少（filler 占位无法作为滚动余量），导致滚不到底、看不全左侧被删的行。改为取 a/b 两个 scrollbind 窗口中**缓冲区行数最多**的那个当锚点，新增/删除都能覆盖全文滚动
- relpath / BufWritePost 仓库归属判断补 '/' 边界，姊妹目录（如 proj2 vs proj）不再误判为仓内
- **修复 diff 视图行号丢失**：`vim.wo[win].X = val` 等同于 `:set`（同时改全局默认），`hide_chrome` 给 panel 设 `number=false` 后全局默认被污染，后续所有新窗口继承 `false`。改用 `nvim_set_option_value(..., scope='local')` 只改目标窗口。同步修复 `view.lua` 全部 19 处 `{ win = win }` 调用、`panel.lua` 的 `diff/scrollbind/cursorbind` 设置
- git index 加载失败的 fallback tree 复用 `Tree.new_root()`（带 is_dir），count_files 不再把空根当 1 个文件、commit hint 不再误显 "Commit 1 staged"
- discard 某文件失败时回调链不再中断，untracked 删除与面板刷新照常进行，UI 不再停留在与磁盘不一致的陈旧状态
- 窄终端单栏冲突视图不再绑定无效的 `<` / `>` 接受键（按了没反应误导用户），冲突改用左栏整文件级 accept ours/theirs 解决
- diff3/zdiff3 冲突风格下 `<` 接受 ours 不再把 `|||||||` 基线标记及 base 段内容一并写入，只保留 ours 内容
- 极快切换文件时读取已失效的 diff buffer 不再抛 `Invalid buffer id`（schedule_diff_sync 补 buf 有效性校验，与 c_buf 分支对齐）
- 反复 open/close 面板后 WinResized 监听不再线性累积、每次缩放重复触发，始终只保留一个
- gitsigns 暂存/重置后若同时触发保存，右侧 diff 不再偶发漏刷（reshow 不再被 BufWritePost 的去抖吞掉）
- 比较模式顶部 Compare 标题行点击/回车不再触发无效折叠，也不再悄悄污染 `section_folds` 状态（其下目录折叠不受影响）
- commit 浮窗提交进行中连按两次 `<C-s>` 不再发起两次提交（第二次报 nothing to commit），并支持外部关窗后正常重开
- 对比/历史版本视图按 `gf` 跳转工作区文件时，历史版本行数多于当前文件不再定位失败、光标停在第 1 行（clamp 行号）
- 对比/查看 commit 时含中文等非 ASCII 文件名的差异现在能正常显示双栏 diff（diff_names 改用 `-z` 按 NUL 解析）
- 帮助浮窗（`g?`）的 `l` 展开、点击折叠、`<C-e>`/`<C-y>` 滚动 diff 归入 Navigate/View 分类并显示图标，不再落入末尾 Other
- 程序化调用或 state 残留陈旧 panel buffer 时打开帮助浮窗不再因无效 buffer 报错，守卫会安全退出

### Refactored

- detect_git_root 改用 vv-utils.git.root
- inline diff / resize / discard-untracked 改用 vv-utils（timer.debounce + fs.delete），移除手搓 uv timer 与逐类型删除分支
- **init.lua 拆分为 4 个子模块**（872 → 147 行）：`core/lifecycle.lua`（open/close/toggle）、`core/keymaps.lua`（panel 快捷键）、`core/panel_ops.lua`（preview/activate/fold/action/layout）、`core/commands.lua`（commit/push/pull/goto_file/yank）。init.lua 仅保留 config + setup + 子模块挂载，对外 API 不变。减少 staged diff 时 treesitter 大文件解析闪烁

- **修复 renamed 文件暂存报错**：从 Changes 区按 `-` 暂存 renamed 文件时，`collect()` 无条件将 rename 旧路径附加到 `git add` 参数，但旧文件已不存在导致 `fatal: pathspec did not match any files`。改为仅在 unstage 路径（`side == 'staged'`）时附加旧路径
- **修复 Changes（unstaged）文件预览无代码着色**：`get_worktree_buffer` 通过 `bufadd` + `bufload` 加载 buffer 时，在 `vim.schedule_wrap` 异步回调上下文中 FileType autocmd 链未完整触发 treesitter；而 `create_rev_buffer`（staged 路径）显式调用了 `vim.treesitter.start` 所以不受影响。新增 `ensure_buf_highlighting` 在 `attach_single` 和 `attach_dual` 统一兜底 filetype 检测 + treesitter attach
- 修复 `p` (push) 成功后，左侧面板未自动刷新导致未推送 commit 数量没更新的问题
- 修复 `s` (切换暂存状态) 和 `o` (打开文件) 快捷键被意外添加到 `<Nop>` 禁用列表导致无法使用的问题
- **diff 视图 zR/zM 折叠 snap-back**：用户全局 `zR`/`zM` 映射到 nvim-ufo 时，ufo 的 `:%foldopen!` 不动 `foldlevel`，TTY 重绘 / 第三方插件 `WinScrolled` 回调会让所有折叠瞬间塌回去。在 a_buf / b_buf 上 buffer-local 包装全部 18 个 fold 命令为 `vim.cmd("normal! ...")`，用 `:normal!` 绕过用户映射跑 vanilla 实现
- **修复缺失字符级 diff**：双栏 / 单栏两条路径之前都没接入 nvim 0.11+ `inline:char` + `DiffTextAdd` + word-diff 算法，"改动行" 看起来是整段同色，与 VSCode / gitsigns 的视觉脱节。本次补齐两条路径的字符级渲染管线
- **修复单栏删除侧上下文与改动字符塌成同色**：a 侧 word-diff 上下文之前误用 `VVGitDiffAddAsDelete`（在新两级配色下已是深红），与"改动字符也深红"无差别。改用 `VVGitDiffChangeDelete`（浅红），与 b 侧 `VVGitDiffChange` + `VVGitDiffText` 的"浅 + 深"层次对称

## 0.1.0 (2026-04-25)

- 首个公开版本：VSCode 风 git diff 双栏视图（panel + a_win + b_win，专属 tabpage 隔离）
