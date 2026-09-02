-- 右栏 diff 视图：双栏（a | b）或单栏（只 b）
--
-- 窗口布局模型：
--   [panel] [a_win] [b_win]   ← 正常双栏
--   [panel] [b_win]           ← 新增/删除文件降级单栏
--
-- 复用规则：
--   - 切换文件时优先复用已有 a/b 窗口，只 set_buf（更顺滑）
--   - 双栏 → 单栏切换：关闭 a_win，保留 b_win
--   - 单栏 → 双栏切换：在 b_win 左侧新建 a_win

local api = vim.api
local Git = require('vv-git.git')
local InlineDiff = require('vv-git.inline_diff')
local FilePolicy = require('vv-git.file_policy')
local FileHighlight = require('vv-utils.fs.file_info_highlight')
local FileRender = require('vv-utils.fs.file_render')
local RightKeymaps = require('vv-git.right.keymaps')
local RightOptions = require('vv-git.right.options')
local Buffers = require('vv-git.right.buffers')
local Conflict = require('vv-git.right.conflict')
local DirSummary = require('vv-git.right.dir_summary')
local Layout = require('vv-git.right.layout')
local Plan = require('vv-git.right.plan')

local M = {}

-- 依赖注入：由 init.setup 调 M.configure 填入，避免 view → init 的反向 require
---@class VVGitViewHandlers
---@field get_config fun():table
---@field on_close fun()
---@field on_goto_file fun()
---@field on_yank_abs_path fun()
---@field on_toggle_stage fun()
---@field on_next_file fun()
---@field on_prev_file fun()
---@class VVGitViewHandlerOverrides
---@field get_config? fun():table
---@field on_close? fun()
---@field on_goto_file? fun()
---@field on_yank_abs_path? fun()
---@field on_toggle_stage? fun()
---@field on_next_file? fun()
---@field on_prev_file? fun()
---@field on_help? fun()
local handlers = {
  get_config       = function() return { fold_unchanged = true } end,
  on_close         = function() end,
  on_goto_file     = function() end,
  on_yank_abs_path = function() end,
  on_toggle_stage  = function() end,
  on_next_file     = function() end,
  on_prev_file     = function() end,
  on_help          = function() end,
}

local right_keymaps
local right_options
local right_layout

local function configure_runtime()
  local config = handlers.get_config()
  right_keymaps = RightKeymaps.new({
    callbacks = {
      close = function() handlers.on_close() end,
      goto_file = function() handlers.on_goto_file() end,
      yank_abs_path = function() handlers.on_yank_abs_path() end,
      toggle_stage = function() handlers.on_toggle_stage() end,
      next_file = function() handlers.on_next_file() end,
      prev_file = function() handlers.on_prev_file() end,
      help = function() handlers.on_help() end,
    },
    next_file_key = config.keymap_next_file or false,
    prev_file_key = config.keymap_prev_file or false,
    revision_mappings = config.revision_mappings or {},
  })
  right_options = RightOptions.new({
    fold_unchanged = config.fold_unchanged ~= false,
    diff_nowrap = config.diff_nowrap == true,
  })
  local conflict_result_ratio = tonumber(config.conflict_result_ratio) or 0.5
  right_layout = Layout.new({
    conflict_result_ratio = math.min(0.9, math.max(0.1, conflict_result_ratio)),
    on_remove_result_buffer = function(buf)
      right_keymaps.remove(buf)
      Conflict.remove_keymaps(buf)
    end,
  })
end

---@param overrides VVGitViewHandlerOverrides
function M.configure(overrides)
  handlers = vim.tbl_extend('force', handlers, overrides or {})
  configure_runtime()
end

---@param path string absolute path
---@return VVFsFileInfo?
local function binary_info(path)
  return FilePolicy.binary_info(path, handlers.get_config().binary)
end

configure_runtime()

local IGNORE_KEY = api.nvim_replace_termcodes('<Ignore>', true, false, true)

local function schedule_diff_sync(a_win, a_buf, b_win, b_buf, c_win, c_buf)
  vim.schedule(function()
    pcall(vim.cmd, 'diffupdate')
    for _, w in ipairs({ a_win, b_win }) do
      if api.nvim_win_is_valid(w) then
        api.nvim_win_call(w, function() pcall(vim.cmd, 'normal! zX') end)
      end
    end
    if not (api.nvim_win_is_valid(a_win) and api.nvim_win_is_valid(b_win)) then return end
    -- a_buf/b_buf 是 bufhidden=wipe scratch，快速切文件时 win 仍 valid 但其 buf
    -- 可能已被换走/wipe（旧 schedule 回调晚于新 set_buf 执行）→ 校验后再读，
    -- 与下方 c_buf 分支的 nvim_buf_is_valid 写法对齐，避免 "Invalid buffer id"
    if not (api.nvim_buf_is_valid(a_buf) and api.nvim_buf_is_valid(b_buf)) then return end
    local b_lines = api.nvim_buf_get_lines(b_buf, 0, -1, false)
    local a_lines = api.nvim_buf_get_lines(a_buf, 0, -1, false)
    -- 仅用于定位首个 hunk 的光标行，却会跑一遍最重的 myers+linematch 全量 diff
    -- 与 inline 单栏路径一致用 inline_diff_max_lines 设上限：超限直接跳过，
    -- 让光标停留在当前行（原生 diff-mode 高亮/折叠不受影响）
    local cfg = handlers.get_config()
    local max = cfg.inline_diff_max_lines or 10000
    local first = (#a_lines <= max and #b_lines <= max)
        and InlineDiff.first_hunk_b_line(a_lines, b_lines)
        or nil
    local row = first or api.nvim_win_get_cursor(b_win)[1]
    local b_max = api.nvim_buf_line_count(b_buf)
    local a_max = api.nvim_buf_line_count(a_buf)
    pcall(api.nvim_win_set_cursor, b_win, { math.min(row, b_max), 0 })
    pcall(api.nvim_win_set_cursor, a_win, { math.min(row, a_max), 0 })
    if c_win and c_buf then
      local c_max = api.nvim_buf_is_valid(c_buf) and api.nvim_buf_line_count(c_buf) or row
      if api.nvim_win_is_valid(c_win) then
        pcall(api.nvim_win_set_cursor, c_win, { math.min(row, c_max), 0 })
      end
    end
    if first then
      api.nvim_win_call(b_win, function() pcall(vim.cmd, 'normal! zz') end)
    end

    api.nvim_win_call(b_win, function()
      pcall(vim.cmd, 'syncbind')
      -- :syncbind 会置位 Neovim 内部的 did_syncbind，之后第一次在 scrollbind 窗口里
      -- 发生的滚动检查只重置标志、不做同步。面板驱动的 <C-e>/<C-y> 和 scrollbar 点击
      -- 都是 nvim_win_call + normal! 滚动，首次会被吞掉、另一侧不跟随，第二次才靠
      -- scrollopt=jump 补齐。这里立刻执行一个空操作 normal 命令把标志消费掉
      pcall(vim.cmd, 'normal! ' .. IGNORE_KEY)
    end)
  end)
end

-- 按 section 路由：
--   staged:   a=HEAD (scratch)   vs  b=:0: (scratch，index 版)   —— 只看增量 staged
--   unstaged: a=:0:  (scratch)   vs  b=worktree (可编辑)          —— 只看未 stage 部分
-- 一侧内容缺失时降级为单栏：
--   staged   + A/??: HEAD 无此文件 → 单栏显示 :0:
--   staged   + D   : :0: 无此文件 → 单栏显示 HEAD（看被删前内容）
--   unstaged + ??  : :0: 无此文件 → 单栏显示工作区
--   unstaged + *D  : 工作区无此文件 → 单栏显示 :0:
-- 任一 git show 失败（二进制/LFS/非 UTF-8）→ 再降一级到工作区单栏
---@param state table
---@param node table  tree node（leaf file）
---@param section 'staged'|'unstaged'|'compare'|'conflicts'
---@param force_single boolean?  true → 强制走单栏分支（窄终端降级用）；正常 dual diff 时为 false/nil
---@param root string?  节点所属仓库根（子仓库时为子仓库根）；默认父仓库根
function M.show(state, node, section, force_single, root)
  -- 提前 return 前清掉 _reshow_view 刚设置但尚未绑定 req 的 reshow 全局，
  -- 否则它会泄漏给下一个普通 preview 被误消费（把焦点错误地还给旧 diff 窗口）
  local function drop_unbound_reshow()
    if state._reshow_restore_req == nil then state._reshow_restore_win = nil end
  end

  local owner = root or state.git_root
  local abspath = owner .. '/' .. node.relpath
  local info = not node.is_dir and binary_info(abspath) or nil

  local xy = node.xy or ''
  local compare = state.compare
  local plan
  local intrinsic_single

  -- 目录和二进制都只有单侧内容可展示，没有 a/b 两版可比，走同一条单栏路径
  if node.is_dir or info then
    intrinsic_single = true
  else
    plan = Plan.resolve({
      section = section,
      xy = xy,
      compare_status = node.compare_status,
      force_single = force_single == true,
      from_rev = compare and compare.from_rev or nil,
      to_rev = compare and (compare.to_rev or 'HEAD') or nil,
      relpath = node.relpath,
      old_relpath = node.old_relpath,
    })
    if not plan then drop_unbound_reshow(); return end
    intrinsic_single = plan.intrinsic_single
  end

  -- 异步竞态守卫：每次 show 分配单调递增 req_id。快速切换文件时，嵌套 git show
  -- 回调可能乱序到达，用 req_id 确认当前请求仍是最新才继续。否则 scratch buf
  -- （bufhidden=wipe 因从未挂到窗口而不会触发）需要手动删掉防漏
  local req_id = (state._show_req_id or 0) + 1
  state._show_req_id = req_id

  -- _reshow_restore_win 由 _reshow_view 在调用本函数前设置，仅供「这一次 reshow」
  -- 在成功 attach 后把焦点还给它捕获的窗口。把它和当次 req_id 绑定：只有持有该
  -- req_id 的 show 才能消费它。否则一旦这次 reshow 被更新的 preview 超越（req_id
  -- 错位、alive() 提前 return 而来不及清理），残留的全局会被下一次普通 preview 误
  -- 消费，把焦点错误地还给旧 diff 窗口。普通 preview 自己从不设置该全局，故其
  -- req_id 不会匹配，会落到 panel 兜底分支
  local reshow_restore_win
  if state._reshow_restore_win and state._reshow_restore_req == nil then
    reshow_restore_win = state._reshow_restore_win
    state._reshow_restore_req = req_id
  end

  -- 子仓库：node.relpath 已相对其所属仓库根（每个子仓库各建独立树），故 git show / index
  -- 取数直接 `git -C <owner>` + node.relpath，无需路径换算；owner == 父根时退化为改造前行为
  -- compare 模式是父仓库专属（其文件列表来自父仓 git diff），root 传 nil → owner = 父根

  -- 切换前的 b_buf：切到不同文件后需从旧 b_buf 拆掉 q/gf，避免它在 bufferline 里被
  -- 其它窗口打开时仍响应（a_buf 是 bufhidden=wipe，自动清理无需额外处理）
  local prev_b_buf = state.view and state.view.b_buf
  -- 切换前若挂着 inline diff 的 TextChanged autocmd，先拆掉再切；否则旧 buf 上的
  -- 定时器还会触发，把已经替换走的 a_lines 应到新 buf 上
  if state.view and state.view._inline_cleanup then
    pcall(state.view._inline_cleanup)
  end

  -- 本次 show 持有 reshow 目标时，把绑定的全局清掉（消费成功 / 被超越丢弃都要清），
  -- 避免 _reshow_restore_win / _reshow_restore_req 残留泄漏到后续 preview
  local function clear_reshow_restore()
    if state._reshow_restore_req == req_id then
      state._reshow_restore_win = nil
      state._reshow_restore_req = nil
    end
  end

  -- 公共守卫：回调进来时 req_id 错位或 tab 关了 → 丢弃结果
  -- 只 wipe vv-git 自建的 scratch；工作区 buf 可能别人还在用，不能动
  local function alive(bufs_to_wipe)
    if state._show_req_id == req_id
        and state.tabpage and api.nvim_tabpage_is_valid(state.tabpage) then
      return true
    end
    clear_reshow_restore()
    Buffers.wipe_scratch(bufs_to_wipe)
    return false
  end

  local function focus_back_to_panel()
    local rw = reshow_restore_win
    clear_reshow_restore()
    if rw then
      if api.nvim_win_is_valid(rw) then
        api.nvim_set_current_win(rw)
      end
      return
    end
    local pw = state.panel and state.panel.win
    if pw and api.nvim_win_is_valid(pw) then
      api.nvim_set_current_win(pw)
    end
  end

  -- 前向声明：render_* 互相调用（降级时）需要先声明才能跨向引用
  local render_single_worktree, render_single_rev
  local render_single_rev_with_inline, render_serial_rev_with_inline
  local render_single_worktree_with_inline
  local render_dual_rev_rev, render_dual_rev_worktree
  local render_conflict_triple

  --- 给 scratch buffer 提供真实 Git 来源，供 statuscol / scrollbar 投影行级 marker
  ---@param buf integer
  ---@param side 'new'|'old'
  local function set_git_diff_source(buf, side)
    if not vim.b[buf].vv_git_scratch then return end

    if section == 'staged' then
      vim.b[buf].vv_git_diff_source = {
        root = owner,
        path = node.relpath,
        mode = 'staged',
        side = side,
      }
    elseif section == 'compare' and state.compare then
      vim.b[buf].vv_git_diff_source = {
        root = owner,
        path = side == 'old' and (node.old_relpath or node.relpath) or node.relpath,
        from_rev = state.compare.from_rev,
        to_rev = state.compare.to_rev or 'HEAD',
        side = side,
      }
    elseif section == 'conflicts' then
      vim.b[buf].vv_git_diff_source = {
        root = owner,
        path = node.relpath,
        from_index_stage = 2,
        to_index_stage = 3,
        side = side,
        marker_kind = 'U',
      }
    end

    if vim.b[buf].vv_git_diff_source then
      local ok, statuscol_git = pcall(require, 'vv-statuscol.git')
      if ok then statuscol_git.refresh(buf) end
    end
  end

  -- 单栏挂载：只 b_win + b_buf；不动 diff opts
  -- a_lines（可选）：传入则在 b_buf 上叠 inline diff（行级 add/change + 删除虚拟行）
  -- 仅 force_single 的常规改动文件会传；intrinsic_single（A/D/?? 等）不传，保持空白
  ---@param b_buf integer
  ---@param a_lines string[]?
  ---@param side? 'new'|'old'
  local function attach_single(b_buf, a_lines, side)
    local b_win = right_layout.ensure(state, false)
    if not b_win then
      Buffers.wipe_scratch({ b_buf })
      vim.notify('[vv-git] No main window available', vim.log.levels.ERROR); return
    end

    state.view = {
      mode = 'single', section = section, path = node.relpath, root = owner,
      b_win = b_win, b_buf = b_buf,
      node = node, intrinsic_single = intrinsic_single, _show_req_id = req_id,
    }
    right_layout.keep_scrollbar(b_win)

    if side then set_git_diff_source(b_buf, side) end
    if section == 'compare' then vim.w[b_win].vv_statuscol_git_disabled = nil end

    local ok, err = pcall(api.nvim_win_set_buf, b_win, b_buf)

    if not ok then
      if not tostring(err):find('E828') then error(err) end
    end

    right_options.restore(b_win)
    Buffers.ensure_highlighting(b_buf, node.relpath)

    if prev_b_buf and prev_b_buf ~= b_buf then right_keymaps.remove(prev_b_buf) end
    right_keymaps.install(b_buf)

    -- scratch buffer（只读 rev 视图）也阻止 Insert mode
    if vim.b[b_buf].vv_git_scratch then right_keymaps.block_insert(b_buf) end

    -- inline diff：worktree b_buf（unstaged，可编辑）→ 挂 live 钩子；scratch b_buf
    -- （staged，固定）→ 一次性 apply 即可
    -- opts.b_win + opts.fold_unchanged：让 InlineDiff 同时给 b_win 创建 manual fold，
    -- 仿 dual mode 的 foldmethod=diff 自动折叠未改动行
    if a_lines then
      -- InlineDiff 会改 foldmethod/foldlevel/foldcolumn 等 win-local 选项；先 save 一下
      -- b_win 的原值，让后续 close / 切回 dual 时能精确还原用户初值
      right_options.save(b_win)

      local cfg = handlers.get_config()
      local opts = {
        b_win = b_win,
        fold_unchanged = cfg.fold_unchanged ~= false,
      }

      local max = cfg.inline_diff_max_lines or 10000
      -- M.apply / attach_live 都返回首个 hunk 的 b 侧目标行，省得再跑一遍 vim.diff
      -- 无 hunk（罕见，理论不会进 force_single 路径）→ first 为 nil，保持光标在 1
      local first
      if vim.b[b_buf].vv_git_scratch then
        first = InlineDiff.apply(b_buf, a_lines, api.nvim_buf_get_lines(b_buf, 0, -1, false), max, opts)
      else
        state.view._inline_cleanup, first = InlineDiff.attach_live(b_buf, a_lines, max, opts)
      end

      if first and api.nvim_win_is_valid(b_win) then
        pcall(api.nvim_win_set_cursor, b_win, { first, 0 })
        api.nvim_win_call(b_win, function() pcall(vim.cmd, 'normal! zz') end)
      end
    end

    -- 冲突单栏：winbar 显示 theirs（b 侧）信息；切离冲突文件则清掉
    -- 注意：窄屏单栏的 b_buf 是纯净 :3:（theirs）scratch，既无冲突标记也无
    -- view.c_buf，hunk 级 accept 无从下手 → 不装 < / > 死键误导用户，改由左
    -- panel 的 accept_ours/accept_theirs（整文件级）解决冲突
    if section == 'conflicts' then
      Conflict.set_winbar(b_win, state, 'MERGE_HEAD', owner)
    else
      Conflict.clear_winbar(b_win)
    end

    focus_back_to_panel()
  end

  -- 双栏挂载：a_win + b_win，apply diff opts，延迟 zX + syncbind
  local function attach_dual(a_buf, b_buf)
    local b_win, a_win = right_layout.ensure(state, true)
    if not a_win or not b_win then
      -- 两侧若是 scratch 则一并 wipe；worktree buf 不能动
      Buffers.wipe_scratch({ a_buf, b_buf })
      vim.notify('[vv-git] Failed to create diff window', vim.log.levels.ERROR); return
    end

    -- 先更新 state.view（在应用 diff options 触发 BufWinEnter 之前），
    -- 否则自检 autocmd 会把"正在切换的新 buf"误认为 stale 而把视图拆掉
    state.view = {
      mode = 'diff2', section = section, path = node.relpath, root = owner,
      a_win = a_win, a_buf = a_buf,
      b_win = b_win, b_buf = b_buf,
      node = node, intrinsic_single = intrinsic_single, _show_req_id = req_id,
    }
    right_layout.keep_scrollbar(b_win)

    if section == 'compare' then set_git_diff_source(a_buf, 'old') end

    set_git_diff_source(b_buf, 'new')
    if section == 'compare' then
      vim.w[a_win].vv_statuscol_git_disabled = nil
      vim.w[b_win].vv_statuscol_git_disabled = nil
    end

    local ratio = handlers.get_config().diff_ratio
    if ratio and ratio[1] and ratio[2] and (ratio[1] + ratio[2]) > 0 then
      local total = api.nvim_win_get_width(a_win) + api.nvim_win_get_width(b_win)
      api.nvim_win_set_width(a_win, math.floor(total * ratio[1] / (ratio[1] + ratio[2])))
    end

    right_options.apply_diff(a_win, a_buf, 'a')
    right_options.apply_diff(b_win, b_buf, 'b')
    Buffers.ensure_highlighting(a_buf, node.relpath)
    Buffers.ensure_highlighting(b_buf, node.relpath)

    if prev_b_buf and prev_b_buf ~= b_buf then right_keymaps.remove(prev_b_buf) end
    right_keymaps.install(a_buf)
    right_keymaps.install(b_buf)
    right_keymaps.block_insert(a_buf)

    -- attach_dual 只服务 staged / unstaged / compare；冲突始终走 conflict3 或 single
    Conflict.clear_winbar(a_win)
    Conflict.clear_winbar(b_win)

    schedule_diff_sync(a_win, a_buf, b_win, b_buf)
    focus_back_to_panel()
  end

  -- Result winbar 右侧的键位提示：按键用主题高亮色，说明文字降为 Comment
  local RESULT_HINTS = {
    { '<', 'ours' }, { '>', 'theirs' }, { '=', 'both' }, { 'g?', 'help' },
  }
  local function result_winbar()
    local parts = {}
    for _, hint in ipairs(RESULT_HINTS) do
      parts[#parts + 1] = '%#VVGitWinbarKey#' .. hint[1] .. '%#VVGitWinbarHint# ' .. hint[2]
    end
    return '%#Title# Result%* — worktree (edit to resolve)'
      .. '%=' .. table.concat(parts, '  ') .. ' %*'
  end

  -- 三栏冲突挂载：a=:2:(ours) | b=:3:(theirs)，底部 c=worktree（可编辑，滚动同步）
  local function attach_conflict_triple(a_buf, b_buf, c_buf)
    local b_win, a_win, c_win = right_layout.ensure_conflict(state)
    if not a_win or not b_win or not c_win then
      Buffers.wipe_scratch({ a_buf, b_buf })
      vim.notify('[vv-git] Failed to create conflict windows', vim.log.levels.ERROR); return
    end
    state.view = {
      mode = 'conflict3', section = section, path = node.relpath, root = owner,
      a_win = a_win, a_buf = a_buf,
      b_win = b_win, b_buf = b_buf,
      c_win = c_win, c_buf = c_buf,
      node = node, intrinsic_single = intrinsic_single, _show_req_id = req_id,
    }
    right_layout.keep_scrollbar(b_win)
    set_git_diff_source(b_buf, 'new')

    right_options.apply_diff(a_win, a_buf, 'a')
    right_options.apply_diff(b_win, b_buf, 'b')
    Buffers.ensure_highlighting(a_buf, node.relpath)
    Buffers.ensure_highlighting(b_buf, node.relpath)

    -- c_win：可编辑工作区文件，不开 diff 模式，scrollbind 保持滚动粗对齐
    right_options.apply_result(c_win, c_buf)
    api.nvim_set_option_value('winbar', result_winbar(), { win = c_win, scope = 'local' })
    Buffers.ensure_highlighting(c_buf, node.relpath)

    if prev_b_buf and prev_b_buf ~= b_buf then right_keymaps.remove(prev_b_buf) end
    right_keymaps.install(a_buf)
    right_keymaps.install(b_buf)
    right_keymaps.install(c_buf)
    right_keymaps.block_insert(a_buf)
    right_keymaps.block_insert(b_buf)

    Conflict.set_winbar(a_win, state, 'HEAD', owner)
    Conflict.set_winbar(b_win, state, 'MERGE_HEAD', owner)
    Conflict.install_keymaps(a_buf, state)
    Conflict.install_keymaps(b_buf, state)
    Conflict.install_keymaps(c_buf, state)

    schedule_diff_sync(a_win, a_buf, b_win, b_buf, c_win, c_buf)
    focus_back_to_panel()
  end

  local function dual_rev_fetch(rev_a, rev_b, a_path, b_path, on_both)
    local a_buf, b_buf, a_done, b_done
    local function finalize()
      if not (a_done and b_done) then return end
      if not alive({ a_buf, b_buf }) then return end
      on_both(a_buf, b_buf)
    end
    Buffers.create_revision(owner, rev_a, a_path, function(buf)
      a_buf = buf; a_done = true; finalize()
    end)
    Buffers.create_revision(owner, rev_b, b_path, function(buf)
      b_buf = buf; b_done = true; finalize()
    end)
  end

  render_single_worktree = function()
    attach_single(Buffers.get_worktree(abspath), nil, 'new')
  end

  -- 降级路径静默：UI 变成单栏就是用户可见的信号，WARN notify 反而打断工作流
  render_single_rev = function(rev, path, side)
    Buffers.create_revision(owner, rev, path, function(b_buf)
      if not alive({ b_buf }) then return end
      if not b_buf then
        render_single_worktree()
        return
      end
      attach_single(b_buf, nil, side)
    end)
  end

  -- staged 分类：HEAD ↔ :0:，两侧都需要 git show
  -- 两个 git show 互不依赖，并发发起 + barrier 合流，比串行省掉一次 RTT
  -- （staged 文件 j/k 快速切换时每次都能省 5-50ms，取决于仓库/磁盘）
  render_dual_rev_rev = function(a_rev, b_rev, a_path, b_path, fallback)
    dual_rev_fetch(a_rev, b_rev, a_path, b_path, function(a_buf, b_buf)
      if not a_buf and not b_buf then
        if fallback == 'staged' then render_single_worktree() end
      elseif not a_buf then
        attach_single(b_buf, nil, 'new')
      elseif not b_buf then
        if fallback == 'staged' then
          Buffers.wipe_scratch({ a_buf })
          render_single_rev(a_rev, a_path, 'old')
        else
          attach_single(a_buf, nil, 'old')
        end
      else
        attach_dual(a_buf, b_buf)
      end
    end)
  end

  -- unstaged 分类：rev ↔ worktree，a 侧 git show
  render_dual_rev_worktree = function(a_rev, a_path)
    Buffers.create_revision(owner, a_rev, a_path, function(a_buf)
      if not alive({ a_buf }) then return end
      if not a_buf then
        render_single_worktree()
        return
      end
      attach_dual(a_buf, Buffers.get_worktree(abspath))
    end)
  end

  -- 三栏冲突：:2:(ours) / :3:(theirs) 并发 show；worktree c_buf 直接 get
  -- 任一侧缺失时降级：双侧均失败 → 单栏 worktree；a 失败 → 单栏 theirs；b 失败 → 单栏 worktree
  -- ours（:2:）缺失（UA / DU）时没有 stage 对可比，不再声明必然失败的 stage-pair source
  render_conflict_triple = function(a_rev, b_rev, a_path, b_path)
    local c_buf = Buffers.get_worktree(abspath)
    dual_rev_fetch(a_rev, b_rev, a_path, b_path, function(a_buf, b_buf)
      if not a_buf and not b_buf then
        attach_single(c_buf, nil, 'new')
      elseif not a_buf then
        attach_single(b_buf, nil, nil)
      elseif not b_buf then
        Buffers.wipe_scratch({ a_buf })
        attach_single(c_buf, nil, 'new')
      else
        attach_conflict_triple(a_buf, b_buf, c_buf)
      end
    end)
  end

  -- force_single 专用：staged 时拿 a_rev 内容做 inline diff，b 显示 b_rev 的 scratch
  -- 取 a_rev 失败 → 静默降级为无 inline 的 single（保持文件可见，丢失 hl 提示）
  -- 两次 git show 互不依赖，并发发起 + barrier 合流（仿 render_dual_rev_rev），
  -- 比串行省一次 RTT；快速 j/k 切 staged 文件每次省 5-50ms
  render_single_rev_with_inline = function(a_rev, b_rev, a_path, b_path)
    local a_lines, b_buf, a_done, b_done = nil, nil, false, false
    local function finalize()
      if not (a_done and b_done) then return end
      if not alive({ b_buf }) then return end
      if not b_buf then
        render_single_worktree()  -- b 侧拿不到（二进制 / 删了等）→ 整体降级到 worktree
        return
      end
      -- a_lines 拿不到也无妨：nil 时跳过 inline。冲突时它意味着 ours stage 不存在，
      -- stage-pair source 必然失败，此时不声明 source
      local side = (section == 'conflicts' and not a_lines) and nil or 'new'
      attach_single(b_buf, a_lines, side)
    end
    Git.show(owner, a_rev, a_path, function(lines)
      a_lines = lines; a_done = true; finalize()
    end)
    Buffers.create_revision(owner, b_rev, b_path, function(buf)
      b_buf = buf; b_done = true; finalize()
    end)
  end

  -- compare 窄屏保持原有串行时序：先读取旧 revision，再创建目标 revision buffer
  render_serial_rev_with_inline = function(a_rev, b_rev, a_path, b_path)
    Git.show(owner, a_rev, a_path, function(a_lines)
      if not alive({}) then return end
      Buffers.create_revision(owner, b_rev, b_path, function(b_buf)
        if not alive({ b_buf }) then return end
        attach_single(b_buf, a_lines, 'new')
      end)
    end)
  end

  -- force_single 专用：unstaged 时拿 a_rev 内容做 inline diff，b 是 worktree（可编辑）
  render_single_worktree_with_inline = function(a_rev, a_path)
    Git.show(owner, a_rev, a_path, function(a_lines)
      if not alive({}) then return end
      attach_single(Buffers.get_worktree(abspath), a_lines, 'new')
    end)
  end

  -- Plan 只决定目标形态；异步请求、fallback、资源清理和 attach 生命周期仍由 view 执行
  if node.is_dir then
    local lines = DirSummary.lines(node, node.relpath)
    local buf = Buffers.create_info(lines, abspath)
    FileHighlight.apply(buf)
    attach_single(buf, nil, nil)
  elseif info then
    local lines = FileRender.lines(info, { display_path = node.relpath })
    local buf = Buffers.create_info(lines, abspath)
    FileHighlight.apply(buf)
    attach_single(buf, nil, nil)
  elseif plan.kind == 'single_rev' then
    render_single_rev(assert(plan.rev), assert(plan.path), assert(plan.side))
  elseif plan.kind == 'single_worktree' then
    render_single_worktree()
  elseif plan.kind == 'single_rev_inline' then
    local render = plan.fetch_mode == 'serial'
        and render_serial_rev_with_inline
        or render_single_rev_with_inline
    render(
      assert(plan.a_rev),
      assert(plan.b_rev),
      assert(plan.a_path),
      assert(plan.b_path)
    )
  elseif plan.kind == 'single_worktree_inline' then
    render_single_worktree_with_inline(assert(plan.a_rev), assert(plan.a_path))
  elseif plan.kind == 'dual_rev_rev' then
    render_dual_rev_rev(
      assert(plan.a_rev),
      assert(plan.b_rev),
      assert(plan.a_path),
      assert(plan.b_path),
      assert(plan.fallback)
    )
  elseif plan.kind == 'dual_rev_worktree' then
    render_dual_rev_worktree(assert(plan.a_rev), assert(plan.a_path))
  elseif plan.kind == 'conflict3' then
    render_conflict_triple(
      assert(plan.a_rev),
      assert(plan.b_rev),
      assert(plan.a_path),
      assert(plan.b_path)
    )
  end
end

---当前已挂载 view 是否属于最新 show request
---异步切换期间 state.view 仍是旧 buffer，调用方不得据此再次发起 show
---@param state table
---@return boolean
function M.is_attached_current(state)
  local view = state.view
  if not view then return false end
  -- 兼容外部测试或旧调用方构造的 view；生产 attach 始终写入 _show_req_id
  return view._show_req_id == nil or view._show_req_id == state._show_req_id
end

---从 panel 驱动当前右侧 diff 的全部折叠 / 展开，调用前后焦点窗口不变
---@param state table
---@return boolean handled
function M.toggle_all_folds(state)
  return state.view and right_keymaps.toggle_all_folds(state.view) or false
end

---@param state table
function M.close(state)
  -- close 也是上下文失效边界：即使当前尚未 attach view，也必须废弃所有在途 show
  state._show_req_id = (state._show_req_id or 0) + 1
  local view = state.view

  if not view then return end
  Conflict.reset(state)

  -- inline diff 的 TextChanged autocmd + extmark 在自家 namespace，关 view 必须显式拆
  if view._inline_cleanup then pcall(view._inline_cleanup) end
  if view.a_win and api.nvim_win_is_valid(view.a_win) then
    pcall(api.nvim_win_close, view.a_win, true)
  end

  if view.c_win and api.nvim_win_is_valid(view.c_win) then
    pcall(api.nvim_win_close, view.c_win, true)
  end

  if view.c_buf then
    right_keymaps.remove(view.c_buf)
    Conflict.remove_keymaps(view.c_buf)
  end

  -- b_win 是工作区文件，不主动关，只清 diff opts
  if view.b_win and api.nvim_win_is_valid(view.b_win) then
    right_options.restore(view.b_win)
    vim.w[view.b_win].vv_statuscol_git_disabled = nil
  end

  -- 拆 buf-local 快捷键；a_buf 是 bufhidden=wipe 自动清，b_buf 需显式处理
  if view.b_buf then right_keymaps.remove(view.b_buf) end
  state.view = nil
end

-- 仅清 b_win 的 diff winopts，保留 state.view（narrow 模式降级时用，便于 wide 复原）
---@param state table
function M.clear_b_winopts(state)
  local view = state.view
  if view and view.b_win and api.nvim_win_is_valid(view.b_win) then
    right_options.restore(view.b_win)
  end
end

return M
