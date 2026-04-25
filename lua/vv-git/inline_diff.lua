-- 单栏模式下在 b_buf 上叠加 diff 高亮：vim.diff() 拿 hunks → extmark 摆放
-- 思路仿 lewis6991/gitsigns.nvim：
--   - 加 / 改：line_hl_group 整行染色
--   - 删：把 a 侧那几行拼成 virt_lines 挂到 b_buf 对应位置
--   - 用专用 namespace 与 gitsigns / lsp 互不干扰
--
-- 设计取舍：
--   - 不做 word-diff（行内 char 级），先做行级；后续如需，可挂到 vim.diff 的
--     `result_type = 'indices'` 之外再跑一次 word_diff（同样是 nvim 内置 API）
--   - virt_lines 用 padding 把红底铺到 ~200 列宽，避免删行只染到字符末尾、剩余行尾
--     是默认底色。代价：超长 line 会少几列底色，能接受
--   - 大文件跳过：超过 max_lines 直接 clear，不做 inline diff，避免 vim.diff 卡顿

local api = vim.api

local M = {}

local NS = api.nvim_create_namespace('vv-git-inline-diff')
-- nvim 0.10+ 把 vim.diff 改名 vim.text.diff，老版本仍保留 vim.diff
local diff_fn = (vim.text and vim.text.diff) or vim.diff

local PAD_WIDTH = 200  -- 删行红底铺多宽；够覆盖大部分屏幕
local FOLD_CONTEXT = 6 -- 每个 hunk 上下保留 N 行可见，与 vim 'diffopt' context 默认一致

-- ufo 软依赖：装了就调它的 detach/attach，没装就 no-op。
-- 必须 detach worktree b_buf 上的 ufo——否则它把 foldmethod 改回 manual + 用 lsp/treesitter
-- provider 重算 fold ranges，把我们这套 hunk-based fold 覆盖掉
local function ufo_call(method, buf)
  if package.loaded.ufo then
    pcall(function() require('ufo')[method](buf) end)
  end
end

---@param a_lines string[]   a 侧（HEAD or :0:）
---@param b_lines string[]   b 侧（:0: or worktree）
---@return integer[][]
local function compute_hunks(a_lines, b_lines)
  return diff_fn(table.concat(a_lines, '\n'), table.concat(b_lines, '\n'), {
    result_type = 'indices',
    algorithm = 'myers',
    linematch = 60,  -- 让 vim 把整段大改拆成更小的 add+delete 对，提升对应精度
  })
end

-- 从 hunks 算出 b_buf 中应该折叠的「未改动连续行」范围（仿 vim diff foldmethod）
-- 输出 {{first, last}, ...}（1-based、闭区间），调用方用 :N,Mfold 创建 manual fold
---@param hunks integer[][]
---@param b_total integer
---@param context integer  每个 hunk 上下保留的可见行数
---@return integer[][]
local function compute_fold_ranges(hunks, b_total, context)
  if #hunks == 0 or b_total <= 0 then return {} end

  -- 每个 hunk 在 b 侧的「必须可见」范围（含上下文）：
  --   ac > 0：实际新增/修改的行 [as, as+ac-1]
  --   ac == 0（纯删除）：删除位点在 b 第 as 行附近（as=0 表头部），把 as 那行标记必须可见
  local must_show = {}
  for _, h in ipairs(hunks) do
    local _, _, as, ac = h[1], h[2], h[3], h[4]
    local first, last
    if ac > 0 then
      first, last = as, as + ac - 1
    else
      local p = math.max(as, 1)
      first, last = p, p
    end
    must_show[#must_show + 1] = {
      math.max(1, first - context),
      math.min(b_total, last + context),
    }
  end

  -- 按起点排序后合并相邻 / 重叠
  table.sort(must_show, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, r in ipairs(must_show) do
    local prev = merged[#merged]
    if prev and r[1] <= prev[2] + 1 then
      prev[2] = math.max(prev[2], r[2])
    else
      merged[#merged + 1] = { r[1], r[2] }
    end
  end

  -- 取补集 = 「不在任何 must_show 范围内」的行 → 这些可以折
  local folds = {}
  local cursor = 1
  for _, r in ipairs(merged) do
    if r[1] > cursor then
      folds[#folds + 1] = { cursor, r[1] - 1 }
    end
    cursor = r[2] + 1
  end
  if cursor <= b_total then
    folds[#folds + 1] = { cursor, b_total }
  end
  return folds
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
    api.nvim_set_option_value('foldmethod', 'manual', { win = b_win })
    api.nvim_set_option_value('foldenable', true,     { win = b_win })
    api.nvim_set_option_value('foldlevel', 0,         { win = b_win })
    api.nvim_set_option_value('foldcolumn', '1',      { win = b_win })
    -- 复用 dual mode 的 fold 渲染（foldtext 显示「N lines」+ 不变文本起头）
    api.nvim_set_option_value('foldtext',
      "v:lua.require'vv-git.foldtext'.render()", { win = b_win })
    api.nvim_set_option_value('winhighlight', 'Folded:VVGitFold', { win = b_win })
    for _, f in ipairs(folds) do
      if f[2] > f[1] then
        pcall(vim.cmd, string.format('%d,%dfold', f[1], f[2]))
      end
    end
  end)
end

-- 单个 hunk 在 b 侧的「跳光标目标行」：
--   ac > 0（有新增/修改）→ as（hunk 起始行）
--   ac == 0（纯删除）   → max(as, 1)（删除位点紧挨的下一行；as=0 头部删除取 1）
---@param h integer[]  vim.diff 单条 hunk { rs, rc, as, ac }
---@return integer
local function hunk_b_target_line(h)
  local _, _, as, ac = h[1], h[2], h[3], h[4]
  return ac > 0 and as or math.max(as, 1)
end

---@param a_lines string[]
---@param rs integer  起始行 1-based
---@param rc integer  行数
---@return table[]   virt_lines（每元素是 { {text, hl_group} } 单 chunk）
local function build_deleted_virt_lines(a_lines, rs, rc)
  local out = {}
  for i = rs, rs + rc - 1 do
    local text = a_lines[i] or ''
    -- pad 到 PAD_WIDTH，让红底铺满一行视觉宽度（不到时补空格）
    if #text < PAD_WIDTH then
      text = text .. string.rep(' ', PAD_WIDTH - #text)
    end
    out[#out + 1] = { { text, 'VVGitDiffAddAsDelete' } }
  end
  return out
end

---@param b_buf integer
---@param a_lines string[]
---@param b_lines string[]
---@param max_lines integer  超过则跳过 inline，避免大文件卡
---@param opts? { b_win?: integer, fold_unchanged?: boolean }  传入 b_win 且 fold_unchanged ~= false 时按 hunks 折叠未改动行
---@return integer?  第一个 hunk 在 b 侧的目标行（1-based）；调用方拿来跳光标，省得再跑一遍 vim.diff
function M.apply(b_buf, a_lines, b_lines, max_lines, opts)
  if not (b_buf and api.nvim_buf_is_valid(b_buf)) then return nil end
  api.nvim_buf_clear_namespace(b_buf, NS, 0, -1)
  if #a_lines > max_lines or #b_lines > max_lines then return nil end

  local hunks = compute_hunks(a_lines, b_lines)

  -- 折叠未改动行（仿 dual mode foldmethod=diff）。失败 / 没 b_win / 关闭配置时跳过
  if opts and opts.b_win and opts.fold_unchanged ~= false then
    apply_folds(opts.b_win, b_buf, compute_fold_ranges(hunks, #b_lines, FOLD_CONTEXT))
  end

  for _, h in ipairs(hunks) do
    local rs, rc, as, ac = h[1], h[2], h[3], h[4]

    -- 加 / 改：as..as+ac-1（1-based 在 b_buf）整行高亮
    -- 改（rc>0 且 ac>0）= 绿底；纯加（rc=0）= 也用绿底，色组复用即可
    if ac > 0 then
      local hl = (rc > 0) and 'VVGitDiffChange' or 'VVGitDiffAdd'
      for ln = as, as + ac - 1 do
        pcall(api.nvim_buf_set_extmark, b_buf, NS, ln - 1, 0, {
          line_hl_group = hl,
          priority = 1000,
        })
      end
    end

    -- 删 / 改：a 侧 rs..rs+rc-1 拼 virt_lines 挂到 b_buf 上
    -- 摆放规则（vim.diff 的 as 语义见 _vim.diff probe 实测）：
    --   as == 0           → 顶部删除（哨兵），挂到 b row 0 上方
    --   ac == 0（纯删除）→ 挂在 b row (as-1) 下方（即 as 行的位置，对应被删行原本所在）
    --   ac > 0（修改）   → 挂在 b row (as-1) 上方（让删行视觉上紧贴新行之上）
    if rc > 0 then
      local row, above
      if as == 0 then
        row, above = 0, true
      elseif ac == 0 then
        row, above = as - 1, false
      else
        row, above = as - 1, true
      end
      pcall(api.nvim_buf_set_extmark, b_buf, NS, row, 0, {
        virt_lines = build_deleted_virt_lines(a_lines, rs, rc),
        virt_lines_above = above,
        priority = 1000,
      })
    end
  end

  -- 给调用方返回第一个 hunk 在 b 侧的位置：avoid 让调用方再跑一次 compute_hunks
  if #hunks == 0 then return nil end
  return hunk_b_target_line(hunks[1])
end

---@param b_buf integer
function M.clear(b_buf)
  if b_buf and api.nvim_buf_is_valid(b_buf) then
    api.nvim_buf_clear_namespace(b_buf, NS, 0, -1)
  end
end

-- 找第一个 hunk 在 b 侧的目标行（用来打开文件时自动跳到第一个变更位置）。
-- 规则：
--   ac > 0（有新增/修改）→ 落在该 hunk 第一行（as）
--   ac == 0（纯删除）   → 落在 b 第 as 行（删除位点紧挨的下一个 b 行；as=0 头部删除则取 1）
-- 没 hunk 返回 nil（调用方保留光标在 1）
---@param a_lines string[]
---@param b_lines string[]
---@return integer?
function M.first_hunk_b_line(a_lines, b_lines)
  local hunks = compute_hunks(a_lines, b_lines)
  if #hunks == 0 then return nil end
  return hunk_b_target_line(hunks[1])
end

-- 给 worktree b_buf 挂 TextChanged 去抖：用户每次编辑 200ms 后重算 inline diff
-- 返回 (cleanup, first_b_line)：cleanup 给 attach_single 切文件 / 关 view 时调用；
-- first_b_line 是首次 apply 的 hunks 首行，调用方拿来跳光标，省一次 compute_hunks
---@param b_buf integer
---@param a_lines string[]
---@param max_lines integer
---@param opts? { b_win?: integer, fold_unchanged?: boolean }  转发给 M.apply（fold 也会跟着 hunks 重算）
---@return fun()  cleanup
---@return integer?  first_b_line
function M.attach_live(b_buf, a_lines, max_lines, opts)
  local first = M.apply(b_buf, a_lines, api.nvim_buf_get_lines(b_buf, 0, -1, false), max_lines, opts)

  local timer
  local aug = api.nvim_create_augroup('VVGitInlineDiffLive_' .. b_buf, { clear = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = aug,
    buffer = b_buf,
    callback = function()
      if timer then pcall(timer.close, timer) end
      timer = vim.uv.new_timer()
      if not timer then return end
      timer:start(200, 0, vim.schedule_wrap(function()
        if timer then pcall(timer.close, timer); timer = nil end
        if api.nvim_buf_is_valid(b_buf) then
          M.apply(b_buf, a_lines, api.nvim_buf_get_lines(b_buf, 0, -1, false), max_lines, opts)
        end
      end))
    end,
  })

  local cleanup = function()
    pcall(api.nvim_del_augroup_by_id, aug)
    if timer then pcall(timer.close, timer); timer = nil end
    M.clear(b_buf)
    -- 把 ufo 重新挂到 b_buf 上：它会把 foldmethod 重新接管为 manual + 走 lsp/treesitter
    -- provider 重算 fold ranges，让用户离开 vv-git 后这个 worktree buffer 恢复正常 fold
    ufo_call('attach', b_buf)
  end
  return cleanup, first
end

return M
