-- diff 视图依赖的全局选项：只在存在 diff 窗口期间生效，最后一个 diff 窗口消失后还原
--
-- 'diffopt' / 'scrollopt' 只有全局值，'fillchars' 的 diff 填充符也写在全局值上；
-- 在 setup 里直接改会让用户自己的 :diffthis、甚至从未打开 vv-git 的会话都带上这些设置
--
-- 进入由调用方显式触发（开 diff 之前调 acquire，首帧就按目标选项计算）；
-- 退出靠观察：diff 窗口的关闭路径很多（面板关闭、切换预览、文件对比结束、tab 关闭、用户 :q）
-- 逐个配对 release 容易漏，统一在窗口变化后检查「是否还有 diff 窗口」
local api = vim.api

local M = {}

---@type string diff 空行填充符，由 setup 写入
local diff_fill = ' '

---@type table<string, { original: string, applied: string }>|nil 已接管的选项；nil 表示当前未生效
local held

local augroup = api.nvim_create_augroup('vv-git.diff-options', { clear = true })

---@return table<string, string> 选项名 → 目标全局值
local function desired()
  local diffopt = {}
  for _, item in ipairs(vim.split(vim.go.diffopt, ',', { plain = true })) do
    if item ~= '' and not item:match('^linematch:') and not item:match('^inline:') then
      diffopt[#diffopt + 1] = item
    end
  end
  diffopt[#diffopt + 1] = 'linematch:60'
  diffopt[#diffopt + 1] = 'inline:char'

  local scrollopt = vim.split(vim.go.scrollopt, ',', { plain = true, trimempty = true })
  if not vim.tbl_contains(scrollopt, 'hor') then scrollopt[#scrollopt + 1] = 'hor' end

  local fillchars = {}
  for _, item in ipairs(vim.split(vim.go.fillchars, ',', { plain = true, trimempty = true })) do
    if not item:match('^diff:') then fillchars[#fillchars + 1] = item end
  end
  fillchars[#fillchars + 1] = 'diff:' .. diff_fill

  return {
    diffopt = table.concat(diffopt, ','),
    scrollopt = table.concat(scrollopt, ','),
    fillchars = table.concat(fillchars, ','),
  }
end

---@return boolean
local function has_diff_window()
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_get_option_value('diff', { win = win }) then return true end
  end
  return false
end

---还原仍由本模块持有的选项；期间被用户或其它插件改过的保持现值
function M.release()
  if not held then return end
  for name, entry in pairs(held) do
    if vim.go[name] == entry.applied then pcall(function() vim.go[name] = entry.original end) end
  end
  held = nil
end

local function release_if_unused()
  if held and not has_diff_window() then M.release() end
end

---diff 窗口可能已经减少时调用：推迟到当前事件处理完再数窗口
---关闭 diff 的写入不触发 OptionSet 时（noautocmd、WinClosed 内的写入）由调用方显式补一次
function M.check()
  if held then vim.schedule(release_if_unused) end
end

-- 监听随模块常驻而不是随 acquire 增删：未接管时回调只做一次判空，
-- 也避免其它模块统计自己的 OptionSet 监听时被这里的动态增减干扰
-- WinClosed / TabClosed 覆盖窗口关闭；OptionSet 覆盖窗口保留但退出 diff（切换预览、:diffoff）
api.nvim_create_autocmd({ 'WinClosed', 'TabClosed' }, { group = augroup, callback = M.check })
api.nvim_create_autocmd('OptionSet', { group = augroup, pattern = 'diff', callback = M.check })

---@param config { diff_fill: string }
function M.configure(config)
  diff_fill = config.diff_fill
end

---开启 diff 窗口之前调用；幂等
function M.acquire()
  if held then return end

  held = {}
  for name, value in pairs(desired()) do
    local original = vim.go[name]
    -- 单项失败（如填充符不是单宽字符）不影响其余选项
    if pcall(function() vim.go[name] = value end) then
      held[name] = { original = original, applied = vim.go[name] }
    end
  end
end

return M
