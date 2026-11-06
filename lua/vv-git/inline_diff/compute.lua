-- 独立 worker：只处理可序列化数据，不访问编辑器 API 或插件状态
local diff_fn = (vim.text and vim.text.diff) or vim.diff
local PAD_WIDTH = 200
local FOLD_CONTEXT = 6

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

-- word-diff：把单行拆成 "字符\n字符\n..." 喂给 vim.diff，行号 = byte 索引
-- 仿 lewis6991/gitsigns.nvim lua/gitsigns/diff_int.lua:split_word_diff_line
-- 末尾保留 '\n' 当哨兵：让 vim.diff 把"行尾插入"识别为字符级插入，而不是把整段
-- 拉成 EOF 处的大改。注意是按 Lua 字节切，不是 UTF-8 codepoint——CJK 文件中
-- 多字节 char 会按字节级 diff，可能切到一半字符；ASCII 主导文件无影响
---@param line string
---@return string
local function split_chars(line)
  if line == '' then return '' end
  return table.concat(vim.split(line, ''), '\n') .. '\n'
end

-- denoise：相邻 < GAP 字符的 hunks 合并成一个，避免视觉碎片化
-- 仿 gitsigns lua/gitsigns/diff_int.lua:denoise_hunks。没有这一步会出现：
--   'red,bold' → '#cba6f7,bold' 中间一个共同字符（如 ','）会被还原浅色，
--   字符级染色变成"深 浅 深 浅"破碎感（实测和 gitsigns 对齐过差异）
local DENOISE_GAP = 5

---@param hunks { rs: integer, rc: integer, as: integer, ac: integer }[]
---@return { rs: integer, rc: integer, as: integer, ac: integer }[]
local function denoise_hunks(hunks)
  local out = {}
  for _, n in ipairs(hunks) do
    local h = out[#out]
    if h and (n.as - h.as - h.ac) < DENOISE_GAP then
      -- 区间扩到 [h.start, n.end)：n.start + n.count - h.start
      h.ac = n.as + n.ac - h.as
      h.rc = n.rs + n.rc - h.rs
    else
      out[#out + 1] = n
    end
  end
  return out
end

-- 仅 #removed == #added 时按行 1:1 配对跑 word-diff，否则返回空（gitsigns 同约束）
-- 不平衡的 hunk 没法干净对应行 → 退回 line-level 染色更可靠
--
-- vim.diff 的 indices 微妙之处（gitsigns diff_int.lua:188 注释 "Balance of the
-- unknown offset done in hunk_func"）：rc==0 / ac==0 时 rs/as 是"插入前最后一行"
-- 而非"插入位点"，需要 +1 修正才能让 denoise 的 start+count 算 end 位置正确
---@param removed string[]
---@param added string[]
---@return integer[][] rems  { {line_idx_1based, start_byte_0based, end_byte_0based}, ... }
---@return integer[][] adds
local function run_word_diff(removed, added)
  local rems, adds = {}, {}
  if #removed ~= #added or #removed == 0 then return rems, adds end

  for i = 1, #removed do
    local raw = diff_fn(split_chars(removed[i]), split_chars(added[i]), {
      result_type = 'indices',
      algorithm = 'myers',
    })
    local hunks = {}

    for _, r in ipairs(raw) do
      local rs, rc, as, ac = r[1], r[2], r[3], r[4]
      if rc == 0 then rs = rs + 1 end
      if ac == 0 then as = as + 1 end
      hunks[#hunks + 1] = { rs = rs, rc = rc, as = as, ac = ac }
    end

    for _, h in ipairs(denoise_hunks(hunks)) do
      -- 1-based "byte 行号" → 0-based byte col 区间 [rs-1, rs-1+rc)
      if h.rc > 0 then rems[#rems + 1] = { i, h.rs - 1, h.rs - 1 + h.rc } end
      if h.ac > 0 then adds[#adds + 1] = { i, h.as - 1, h.as - 1 + h.ac } end
    end
  end

  return rems, adds
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
---@param rems integer[][]?  可选 word-diff 结果（{ line_idx_1based, start_byte, end_byte }），
---                          line_idx 相对于本 hunk 的 a 切片（i=1 即 a_lines[rs]）
---                          传入则按区间拆 chunk：被删字符 VVGitDiffTextDelete（深红），
---                          上下文 VVGitDiffChangeDelete（浅红）—— 与 b 侧 VVGitDiffChange 对称
---                          注意 no-rems 分支（纯删除整行）仍用 VVGitDiffAddAsDelete（深红），
---                          因为整行都"被删"，没有"未变上下文"的概念
---@return table[]   virt_lines（每元素是 chunk 列表 { {text, hl_group}, ... }）
local function build_deleted_virt_lines(a_lines, rs, rc, rems)
  -- 把 rems 按 line_idx 分桶，方便逐行查询
  local buckets = {}
  if rems then
    for _, r in ipairs(rems) do
      local lidx = r[1]
      buckets[lidx] = buckets[lidx] or {}
      buckets[lidx][#buckets[lidx] + 1] = { r[2], r[3] }
    end
  end

  local out = {}
  for i = 1, rc do
    local text = a_lines[rs + i - 1] or ''
    if #text < PAD_WIDTH then
      text = text .. string.rep(' ', PAD_WIDTH - #text)
    end

    local regions = buckets[i]
    if not regions or #regions == 0 then
      -- 无 word-diff 数据 = 纯删除整行（rc>0, ac==0），整条铺深红
      out[#out + 1] = { { text, 'VVGitDiffAddAsDelete' } }
    else
      -- change pair（rc==ac）的"被删那一行"：[浅][深][浅][深]...[尾段浅(含 pad)]
      -- 上下文用 ChangeDelete（浅红），与 b 侧 line_hl=VVGitDiffChange（浅绿）形成对称
      -- 不去 overlap：word-diff 同一行的 hunks 天然不重叠（vim.diff 输出严格升序）
      table.sort(regions, function(x, y) return x[1] < y[1] end)
      local chunks, cur = {}, 0

      for _, reg in ipairs(regions) do
        local sc, ec = reg[1], reg[2]
        if sc > cur then
          chunks[#chunks + 1] = { text:sub(cur + 1, sc), 'VVGitDiffChangeDelete' }
        end
        if ec > sc then
          chunks[#chunks + 1] = { text:sub(sc + 1, ec), 'VVGitDiffTextDelete' }
        end
        cur = ec
      end

      if cur < #text then
        chunks[#chunks + 1] = { text:sub(cur + 1), 'VVGitDiffChangeDelete' }
      end
      out[#out + 1] = chunks
    end
  end
  return out
end

---@class VVGitInlineResult
---@field marks table[] { row, column, extmark options }
---@field folds integer[][]
---@field first_b_line? integer

---@param input { a_lines: string[], b_lines: string[] }
---@return VVGitInlineResult
return function(input)
  local a_lines, b_lines = input.a_lines, input.b_lines
  local hunks = compute_hunks(a_lines, b_lines)
  local marks = {}
  for _, h in ipairs(hunks) do
    local rs, rc, as, ac = h[1], h[2], h[3], h[4]

    -- change pair（rc==ac>0）才跑 word-diff：1:1 行配对前提下字符级才对齐
    -- 不平衡的 add/delete 退回纯行级染色，保持行为可预测
    local rems, adds
    if rc > 0 and ac > 0 and rc == ac then
      local removed_slice, added_slice = {}, {}
      for k = 1, rc do
        removed_slice[k] = a_lines[rs + k - 1] or ''
        added_slice[k] = b_lines[as + k - 1] or ''
      end
      rems, adds = run_word_diff(removed_slice, added_slice)
    end

    -- 加 / 改：as..as+ac-1（1-based 在 b_buf）整行高亮
    -- 改（rc>0 且 ac>0）= 绿底；纯加（rc=0）= 也用绿底，色组复用即可
    if ac > 0 then
      local hl = (rc > 0) and 'VVGitDiffChange' or 'VVGitDiffAdd'
      for ln = as, as + ac - 1 do
        marks[#marks + 1] = { ln - 1, 0, {
          line_hl_group = hl,
          priority = 1000,
        } }
      end
      -- word-diff 字符级深绿：priority 1010 > line_hl 的 1000，覆盖在浅绿底之上
      if adds then
        for _, r in ipairs(adds) do
          local lidx, sc, ec = r[1], r[2], r[3]
          local row = (as + lidx - 1) - 1  -- 1-based → 0-based
          marks[#marks + 1] = { row, sc, {
            end_col = ec,
            hl_group = 'VVGitDiffText',
            priority = 1010,
          } }
        end
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
      marks[#marks + 1] = { row, 0, {
        virt_lines = build_deleted_virt_lines(a_lines, rs, rc, rems),
        virt_lines_above = above,
        priority = 1000,
      } }
    end
  end

  return {
    marks = marks,
    folds = compute_fold_ranges(hunks, #b_lines, FOLD_CONTEXT),
    first_b_line = hunks[1] and hunk_b_target_line(hunks[1]) or nil,
  }
end
