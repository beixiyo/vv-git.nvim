# Changelog

## 0.4.0 - 2026-10-22

### Breaking

- `state` 改由 `setup(opts, deps)` 的 `deps.state` 注入，`opts.state` 不再生效
- `config()` 改名为 `get_config()`，不保留旧名
- `mappings` 必须是表

### Changed

- 输入类型统一为 `VVGitOpts`，由 `VVGitConfig` 派生
- 配置存为模块私有变量，内部模块不再经 controller 读取 `_config`

## 0.3.20 - 2026-10-04

### Added

- 新增 `yank_notify` 配置（默认 `false`），可恢复复制路径成功后的提示
- push / pull / publish、提交、手动刷新、新建 worktree 和 stage / unstage / discard 显示操作进度

### Changed

- `Y` 复制路径成功后默认不再弹提示
- discard 未跟踪文件 / 目录改为异步删除，大目录不再冻结界面，单个路径失败不影响其余路径

### Fixed

- discard 后关闭已删除文件的未修改 buffer 并通知 LSP，重新加载已还原文件的未修改 buffer，保留已修改 buffer
- 切换 worktree 或跟随 vv-explorer 切根时显示等待状态，不再残留旧仓库内容
- 修复面板有焦点时右键点击其他窗口误操作
- discard 确认前光标不再跳走

## 0.3.19 - 2026-09-30

### Added

- Worktree 删除显示进度

### Fixed

- 双栏 diff 首次预览、快照转真实 buffer 和重复打开时，顶部纯删除内容立即可见

## 0.3.18 - 2026-09-30

### Added

- 新增 `worktree_preview`（`'buffer'` / `'snapshot'` 或函数）：快照浏览不加载真实文件或挂 LSP，进入右侧后换成真实 buffer；已加载文件和冲突 Result 仍用真实 buffer
- 新增 `snapshot_promote_ms`，停留后自动加载真实 buffer 和诊断，快速途经的文件不加载

### Changed

- 默认 `worktree_preview = 'snapshot'`、`snapshot_promote_ms = 400`；设 `worktree_preview = 'buffer'` 恢复旧行为，详见 [工作区预览](README.zh-CN.md#工作区预览)
- 单按 j/k 立即预览，连续快速切换时才防抖

### Fixed

- j/k 预览不再触发全量 Git 刷新
- 双栏切单栏或重建冲突布局后被动刷新不再失效

## 0.3.17 - 2026-09-26

### Changed

- 打开时先显示加载骨架
- 双栏 diff 定位首个 hunk 不再重算全文差异

### Fixed

- 修复大量变更时 j/k 卡顿，状态未变化的被动刷新不再重画或广播 `VVGitStatusChanged`
- 退出内嵌终端后自动刷新面板
- SSH 远程会话不再绑定 `<Esc>`，避免鼠标点击误关面板

## 0.3.16 - 2026-09-02

### Fixed

- 修复从 ours / theirs 窗口按 `<` / `>` / `=` 无法接受冲突块的问题

## 0.3.15 - 2026-09-02

### Fixed

- 双栏 diff 首次使用 `<C-e>` / `<C-y>` 或 scrollbar 滚动时，两侧立即同步

## 0.3.14 - 2026-09-02

### Added

- 右侧新增 `g?` 帮助，冲突 Result winbar 显示快捷键提示
- 冲突 buffer 新增 `=` 保留两侧内容

### Changed

- `<` / `>` 只接受 Result 光标所在冲突块
- 冲突 scrollbar 仅在上方右侧 theirs diff 显示单轨 `U` 差异

## 0.3.13 - 2026-08-28

### Added

- 非仓库面板新增 `i` 初始化快捷键，以及 `parent_repository`（`'prompt'` / `'always'` / `'never'`）祖先仓库策略

### Fixed

- 右侧 diff 的 `-` 只暂存当前可见文件，忽略同文件在途重复操作，取消刷新后仍可继续操作
- `VVGitToggle` 隐式打开仓库时定位并预览当前文件
- `gf` 跳转保留行列并安全截断，避免回到行首或越界
- 支持为 revision/index scratch 注入键位，配置层 `K` 可向对应工作区文件请求 LSP hover，不覆盖真实 buffer 的 `K`

## 0.3.12 - 2026-08-13

### Added

- `open`、`show_commit` 与 revision 对比 API 新增可选 `on_goto_file(context)` 回调

## 0.3.11 - 2026-08-10

### Changed

- discard 与 worktree 删除增加结构化确认及状态预检，普通删除被 Git 拒绝后才允许确认强制删除
- `X` 按解析后的工作目录执行文件，关闭面板、切根或确认被新请求取代后取消待执行命令

### Fixed

- 关闭面板、切换仓库或重开会话后，旧操作回调不再写回或刷新新会话
- 旧 discard、worktree 删除及执行确认在关闭、切根或被新请求取代后不再产生副作用

## 0.3.10 - 2026-08-07

### Added

- 新增目录变更统计预览，`directory_preview` 默认开启且依赖 `preview`

### Fixed

- 目录预览不再改写当前文件，`gf` 不会误打开目录

## 0.3.9 - 2026-08-06

### Changed

- stage、unstage、commit 与冲突接受按实际 Git index 串行写入，支持共享 `GIT_INDEX_FILE`，避免争抢 `index.lock`
- 连续按 `-` 时立即捕获并推进文件目标，队列结束后统一刷新

### Fixed

- 检测到活动或陈旧 index 锁时明确拒绝操作，不自动删除锁文件
- 关闭面板、切换仓库或提交浮窗失效后，不再启动旧 index 写入或刷新新会话
- 快速 stage / unstage 不再遗留错误提示、跳回旧文件或漏掉后续文件

## 0.3.8 - 2026-08-03

### Changed

- 异步加载、自动刷新、切根与 push / pull / publish 按当前面板和仓库隔离

### Fixed

- 窗口 guard 卸载不再破坏第三方 wrapper 或 `noautocmd` 行为
- File Compare 重入清理不再覆盖后继视图或调用方窗口状态

## 0.3.7 - 2026-08-01

### Added

- `gw` / `:VVGitWorktree` 新增创建、刷新与确认删除
- 新增 `highlights` 配置，可覆盖内建或共享 `VVGit*` 高亮

### Fixed

- 切换 worktree 后旧异步结果不再写回，仅在专属 tab 的 cwd 切换成功后更新仓库根
- 新建 worktree 默认以 main worktree 为布局根，避免嵌套到 linked worktree 内
- 删除前重新检查 locked / dirty 状态，仅 dirty 目标可强制删除
- 修复快速刷新被旧结果覆盖，以及创建后浮窗定位报错

## 0.3.6 - 2026-07-30

### Added

- 右侧 diff buffer 新增 `<C-j>` / `<C-k>` 切换文件

### Fixed

- 修复 diff 连续按 `-` 时目标跳回上一个文件

## 0.3.5 - 2026-07-28

### Fixed

- 修复文件树宽度未持久化

## 0.3.4 - 2026-07-28

### Added

- 新增 `get_target_paths()` 获取多选路径 API

### Fixed

- 右侧 diff 按 `-` 暂存或取消后自动跳到下一个文件，匿名 diff buffer 也可通过外部功能复制文件路径

## 0.3.3 - 2026-07-26

### Changed

- 面板宽度在隐藏、关闭和退出时保存，新增可注入的 `state` 配置

### Fixed

- 重复 `setup()` 从默认配置重新合并并释放旧宽度持久化资源，窗口 guard 卸载不覆盖其他插件
- `VVGitSubrepoDepth` 拒绝非数字参数，异步回调保留中间 `nil` 参数
- 右侧 diff 支持 `-` 暂存或取消当前文件，操作后重建 diff 并保留焦点

## 0.3.2 - 2026-07-25

### Fixed

- `fold_unchanged=false` 在单栏 inline diff 中完全禁用折叠，包括超过 `inline_diff_max_lines` 的文件

## 0.3.1 - 2026-07-19

### Added

- 监听 `User VVExplorerRootChanged` 跟随 vv-explorer 切仓库；面板关闭时记住目录作为下次隐式 `open()` 的候选根，同仓库切目录不重载，无效目录回退 cwd

## 0.3.0 - 2026-07-18

### Added

- 新增 `u` / `:VVGitPublish` 智能发布分支，无 remote 时只询问 `origin` URL
- 左栏新增 `zR` 切换右侧 diff 的全部折叠 / 展开
- 新增 root-aware `open` / revision API、`is_open()` / `get_context()` 及 ready / error / close 生命周期回调

### Breaking

- `require('vv-git')` 不再暴露 `_` 前缀内部方法，外部调用改用 [公开接口](README.zh-CN.md#公开接口)
- revision API 改用 opts table，如 `show_commit(ref, opts)`，将 `root`、`path` 和生命周期回调放入 opts，详见 [Lua API](README.zh-CN.md#lua-api)

### Fixed

- 修复动作提示大小写键位冲突及 push / pull 提交数的单复数显示
- 当前分支名使用主题 Keyword 色，改善与分支图标及仓库名的层级

## [0.2.0] - 2026-07-16

### Added

- 新增 `show_commit`、`compare_with_head`、`compare_refs`、`compare_file`、`stop_compare` 及对应命令，支持外部 picker 展示 revision diff
- 面板操作键使用独立高亮，避免提示色覆盖

### Fixed

- 单文件对比退出后恢复窗口选项及调用方 picker，保留源 buffer 的局部映射

## [0.1.1] - 2026-07-16

### Fixed

- Staged Changes 手动折叠不再被后续渲染或被动刷新自动展开

## [0.1.0] - 2026-07-13

### Added

- 新增 `fold_staged`（默认 `false`），打开面板时可默认折叠 Staged Changes
- 左栏支持 `]c` / `[c` 跳转右侧 diff chunk 并居中，焦点留在面板
- 新增 `subrepo.depth`（默认 `0` 不扫描），子仓库独立折叠并按所属仓库执行 Git 操作，默认跳过 linked worktree
- 新增 `gw` / `:VVGitWorktree` 切换 worktree，浮窗显示当前项、分支及锁定等状态
- 根仓库与子仓库标题显示当前分支或 detached 短 hash，根仓库可独立折叠
- 面板支持方向键导航和 j/k 循环导航，跳过非交互行
- Git 操作后广播 `User VVGitStatusChanged`（`data.root` 为仓库根），供外部插件刷新
- 新增 `preview_debounce_ms` 预览防抖，`0` 禁用
- 各 section 可独立折叠，折叠后光标留在标题行
- 新增 `gc` 查看提交自身变更、`H` 与 HEAD 比较，支持树形目录导航，`<Esc>` 退出比较
- 新增 `<Tab>` 多选（`keymap_select` 可配置），使用 `VVGitPanelSelected` 高亮，`-` / `d` 批量操作，`<Esc>` 优先清空选择，否则关闭面板和 diff
- 二进制文件默认拦截（`binary.intercept=true`），显示文件信息并由系统程序打开，支持 `binary.extensions` 覆盖
- 左侧纯新增对应的填充行显示浅绿背景
- 新增 `highlights` 覆盖 `VVGit*` 配色，切换主题后仍生效
- 监听 `User GitSignsChanged` 自动刷新 diff 并保持焦点
- 打开面板时自动定位有改动的当前文件并展开父目录，否则优先定位 Changes
- 目录图标区分展开 / 收起，支持单击折叠及可配置右键动作（`right_click`，默认 `toggle_stage`）
- 窄屏自动降级为单栏 inline diff，宽度恢复后升回双栏
- 单栏支持新增 / 修改行高亮、原位删除行、字符级差异及未改动代码自动折叠；字符级差异按 byte 切分，CJK 可能切到字符中间
- 双栏启用 Neovim 0.11+ `inline:char`，新增 `VVGitDiffTextAdd` / `VVGitDiffTextAddDelete` 高亮
- 单栏和双栏打开文件时自动定位首个 hunk，`inline_diff_max_lines` 默认 `10000`，超限跳过单栏 inline 渲染
- 面板宽度跨会话持久化，屏蔽 Visual 选择及鼠标拖拽 / 多击选区

### Changed

- 目录行不再显示聚合 Git 状态，最外层文件按 `h` / `←` 可折叠所属 section
- staged 区按 `d` 只取消暂存，不再同时 discard；unstaged 区仍确认后丢弃
- 图标支持展开 / 空目录状态，并保留 `_G.MiniIcons` 回退
- `single_col_threshold` 从窄屏拒绝打开改为单栏降级，任何宽度均可打开
- 拖拽 resize 增加防抖，staged 单栏预览并行读取以减少切换等待
- Diff 配色：`VVGitDiffAdd` / `VVGitDiffAddAsDelete` 为纯增删深色，`VVGitDiffChange` / `VVGitDiffChangeDelete` 为浅色上下文，`VVGitDiffText` / `VVGitDiffTextDelete` 为深色改动字符

### Fixed

- 无 HEAD 的新仓库可取消暂存，保留工作区文件
- 被动刷新保留当前文件位置，j/k 导航不再反复跳回旧行
- 未打开 diff 时隐藏面板不再误关 tab，可再次展开
- 多选冲突文件的 accept ours/theirs 生效，多选 stage / discard 不再误用过期选择或漏掉删除警告
- 切文件或关闭视图后，迟到回调不再重绘 inline diff 或把焦点还给旧窗口
- 大文件双栏 diff 超过 `inline_diff_max_lines` 时跳过首个 hunk 定位，避免卡顿，原生高亮和折叠不受影响
- 旧 commit 回调不再关闭新提交浮窗，提交中重复 `<C-s>` 不再重复提交，外部关窗后可重开
- diff 滚动可覆盖大量删除内容
- 窗口局部选项不再污染后续窗口或导致行号丢失
- 仓库归属判断不再误匹配相似前缀的姊妹目录
- 索引加载失败不再误报一个 staged 文件
- discard 单个文件失败后继续处理未跟踪文件并刷新面板
- 窄屏单栏冲突不再绑定无效的 `<` / `>`，请改用左栏整文件接受
- diff3 / zdiff3 接受 ours 不再写入基线标记及 base 内容
- 快速切文件不再报 `Invalid buffer id`
- 反复开关面板不再累积 resize 监听
- gitsigns 操作与保存同时触发时 diff 不再漏刷
- Compare 标题点击或回车不再无效折叠
- 历史视图 `gf` 跳转超出当前文件的行号时安全截断
- 非 ASCII 文件名可正常显示双栏 diff
- 帮助浮窗正确分类导航 / 视图按键，无效 panel buffer 不再报错
- 减少 staged diff 的 Treesitter 大文件着色闪烁，恢复 unstaged 文件预览的代码着色
- 修复 renamed 文件暂存报错
- push 成功后自动刷新未推送提交数
- 修复 `s` / `o` 快捷键被误禁用
- diff 的 `zR` / `zM` 不再受全局 nvim-ufo 映射影响而折叠回弹
- 单栏删除侧上下文与改动字符恢复分层配色

## 0.1.0 (2026-04-25)

- 首个公开版本：VSCode 风 Git diff 双栏视图，使用专属 tab 隔离
