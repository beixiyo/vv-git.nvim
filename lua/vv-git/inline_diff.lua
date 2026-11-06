-- 单栏 inline diff：后台纯计算，主线程只捕获内容、验证 owner 和应用装饰
local api = vim.api
local Async = require('vv-utils.async')
local M = {}
local NS = api.nvim_create_namespace('vv-git-inline-diff')
local owners = {}

-- ufo 软依赖：装了就调它的 detach/attach，没装就 no-op
-- 必须 detach worktree b_buf 上的 ufo——否则它把 foldmethod 改回 manual + 用 lsp/treesitter
-- provider 重算 fold ranges，把我们这套 hunk-based fold 覆盖掉
local function ufo_call(method, buf)
  if package.loaded.ufo then
    pcall(function() require('ufo')[method](buf) end)
  end
end

-- 应用 manual fold 到 b_win。idempotent：每次 apply（含 TextChanged 重渲染）都会
-- 先 zE 清旧 fold 再重建，与 dual mode foldmethod=diff 的语义对齐
---@param b_win integer
---@param b_buf integer
---@param folds integer[][]  compute_fold_ranges 的输出
local function apply_folds(b_win, b_buf, folds)
  if not api.nvim_win_is_valid(b_win) then return end
  -- 先把 ufo 从 b_buf 上摘掉，否则它会用 lsp/treesitter provider 把我们的
  -- manual fold 覆盖（cleanup 时再 attach 回去）
  ufo_call('detach', b_buf)
  api.nvim_win_call(b_win, function()
    pcall(vim.cmd, 'normal! zE')           -- 清掉所有现存 fold
    api.nvim_set_option_value('foldmethod', 'manual', { win = b_win, scope = 'local' })
    api.nvim_set_option_value('foldenable', true,     { win = b_win, scope = 'local' })
    api.nvim_set_option_value('foldlevel', 0,         { win = b_win, scope = 'local' })
    api.nvim_set_option_value('foldcolumn', '1',      { win = b_win, scope = 'local' })
    -- 复用 dual mode 的 fold 渲染（foldtext 显示「N lines」+ 不变文本起头）
    api.nvim_set_option_value('foldtext',
      "v:lua.require'vv-git.foldtext'.render()", { win = b_win, scope = 'local' })
    api.nvim_set_option_value('winhighlight', 'Folded:VVGitFold', { win = b_win, scope = 'local' })

    for _, f in ipairs(folds) do
      if f[2] > f[1] then
        pcall(vim.cmd, string.format('%d,%dfold', f[1], f[2]))
      end
    end
  end)
end

-- fold_unchanged=false 不只是“不创建默认 fold”，而是禁止 vv-git 单栏视图中的
-- 代码折叠，与 dual mode 的 foldenable=false 语义保持一致
---@param b_win integer
---@param b_buf integer
local function disable_folds(b_win, b_buf)
  if not api.nvim_win_is_valid(b_win) then return end
  ufo_call('detach', b_buf)
  api.nvim_win_call(b_win, function()
    pcall(vim.cmd, 'normal! zE')
    api.nvim_set_option_value('foldenable', false, { win = b_win, scope = 'local' })
    api.nvim_set_option_value('foldcolumn', '0', { win = b_win, scope = 'local' })
  end)
end

function M.clear(b_buf)
  if b_buf and api.nvim_buf_is_valid(b_buf) then
    api.nvim_buf_clear_namespace(b_buf, NS, 0, -1)
  end
end

-- 折叠命令也会移动视口；恢复的是结果抵达时的位置，而不是提交时的位置
local function preserve_view(win, action)
  if not win then return action() end
  api.nvim_win_call(win, function()
    local saved = vim.fn.winsaveview()
    action()
    -- topline 可能与光标分属不同折叠；定点展开避免 winrestview 将其钳到折叠首行
    if vim.fn.foldclosed(saved.topline) ~= -1 then
      vim.cmd(string.format('%dfoldopen!', saved.topline))
    end
    vim.fn.winrestview(saved)
    vim.cmd('normal! zv')
    vim.fn.winrestview(saved)
  end)
end

---@class VVGitInlineOpts
---@field b_win? integer
---@field fold_unchanged? boolean
---@field is_valid? fun(): boolean
---@field navigation? { pending: boolean } 一次性意图，可在 snapshot promote 时转交
---@field is_user_enter? fun(): boolean 排除 view 自己临时切窗
---@field on_initial_ready? fun(result: VVGitInlineResult)

---@param b_buf integer
---@param a_lines string[]
---@param max_lines integer
---@param opts VVGitInlineOpts?
---@param live boolean
---@return fun()
local function attach(b_buf, a_lines, max_lines, opts, live)
  opts = opts or {}
  if owners[b_buf] then owners[b_buf]() end
  local closed, revision, task = false, 0, nil
  local dirty, debounce_ready, initial = false, false, true
  local win, navigation = opts.b_win, opts.navigation
  local cleanup, launch, cancel_debounce
  local autocmds = {}

  local function valid()
    return not closed and owners[b_buf] == cleanup and api.nvim_buf_is_valid(b_buf)
      and (not win or (api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == b_buf))
      and (not opts.is_valid or opts.is_valid())
  end
  local function cancel_navigation()
    if navigation then navigation.pending = false end
  end
  local function watch(events, options)
    autocmds[#autocmds + 1] = api.nvim_create_autocmd(events, options)
  end
  local baseline
  local function view_position()
    return api.nvim_win_call(win, vim.fn.winsaveview)
  end
  local function check_position()
    if navigation and navigation.pending and valid() and baseline
        and not vim.deep_equal(baseline, view_position()) then
      cancel_navigation()
    end
  end

  cleanup = function()
    if closed then return end
    -- promote 可能早于 CursorMoved/WinScrolled 投递；先撤销已被用户接管的意图
    check_position()
    closed = true
    if cancel_debounce then cancel_debounce() end
    for _, id in ipairs(autocmds) do pcall(api.nvim_del_autocmd, id) end
    -- 关闭只逻辑取消；不把 cancelled 当作物理完成或在该 owner 上重派发
    if task then task:cancel() end
    if owners[b_buf] == cleanup then
      owners[b_buf] = nil
      M.clear(b_buf)
      ufo_call('attach', b_buf)
    end
  end
  owners[b_buf] = cleanup
  M.clear(b_buf)
  if win and opts.fold_unchanged == false then
    preserve_view(win, function() disable_folds(win, b_buf) end)
  end
  if win and navigation then
    baseline = view_position()
    watch({ 'CursorMoved', 'CursorMovedI' }, { buffer = b_buf, callback = check_position })
    watch('WinScrolled', { pattern = tostring(win), callback = check_position })
    watch('WinEnter', { callback = function()
      if valid() and api.nvim_get_current_win() == win
          and (not opts.is_user_enter or opts.is_user_enter()) then cancel_navigation() end
    end })
  end

  launch = function()
    if not valid() or task then return end
    dirty, debounce_ready = false, false
    local tick = api.nvim_buf_get_changedtick(b_buf)
    local version = revision
    local b_lines = api.nvim_buf_get_lines(b_buf, 0, -1, false)
    if #a_lines > max_lines or #b_lines > max_lines then
      M.clear(b_buf)
      initial = false
      cancel_navigation()
      return
    end

    task = Async.worker_task({
      total = 1,
      concurrency = 1,
      worker = 'vv-git.inline_diff.compute',
      input = function() return { a_lines = a_lines, b_lines = b_lines } end,
      on_done = function(outcome)
        task = nil
        if not valid() then return end

        if version == revision and tick == api.nvim_buf_get_changedtick(b_buf) then
          check_position()
          if outcome.state == 'completed' then
            local result = outcome.results[1]
            M.clear(b_buf)
            preserve_view(win, function()
              if win and opts.fold_unchanged ~= false then apply_folds(win, b_buf, result.folds) end
              for _, mark in ipairs(result.marks) do
                api.nvim_buf_set_extmark(b_buf, NS, mark[1], mark[2], mark[3])
              end
            end)
            if initial and opts.on_initial_ready then opts.on_initial_ready(result) end
          elseif outcome.state == 'failed' then
            M.clear(b_buf)
            if win and opts.fold_unchanged ~= false then
              preserve_view(win, function() apply_folds(win, b_buf, {}) end)
            end
            vim.notify('[vv-git] inline diff failed: ' .. tostring(outcome.error), vim.log.levels.ERROR)
          end
          initial = false
          cancel_navigation()
        else
          cancel_navigation()
        end
        -- 编辑期间不 cancel 旧 work。单项任务真实结束才释放槽，最多补一次最新 dirty
        if dirty and debounce_ready then launch() end
      end,
    })
    task:start()
  end

  local recompute
  if live then
    recompute, cancel_debounce = require('vv-utils.timer').debounce(function(version)
      -- 旧 timer 已 schedule 的回调无法撤回，不得抢在新编辑的200ms尾沿之前派发
      if not valid() or version ~= revision then return end
      debounce_ready = true
      if dirty then launch() end
    end, 200)
  end
  watch({ 'TextChanged', 'TextChangedI' }, { buffer = b_buf, callback = function()
    revision = revision + 1
    cancel_navigation()
    if live then
      dirty, debounce_ready = true, false
      recompute(revision)
    end
  end })
  watch('BufWipeout', { buffer = b_buf, callback = cleanup })
  launch()
  return cleanup
end

---一次性 scratch/snapshot 请求；同步返回 cleanup，不返回同步首 hunk
---@param opts VVGitInlineOpts?
function M.apply_async(b_buf, a_lines, max_lines, opts)
  return attach(b_buf, a_lines, max_lines, opts, false)
end

---真实 buffer：立即首次计算，编辑后保留旧装饰并按 200ms 尾沿防抖重算
---@param opts VVGitInlineOpts?
function M.attach_live(b_buf, a_lines, max_lines, opts)
  return attach(b_buf, a_lines, max_lines, opts, true)
end

return M
