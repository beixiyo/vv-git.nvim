-- 目录节点的属性预览：把变更树的一棵子树聚合成 `label: value` 行
--
-- 这里的目录是 git 变更的虚拟聚合节点，只包含有改动的文件，所以统计的是「改了多少
-- 个文件、分别是什么状态」。磁盘占用是文件管理器的口径（见 vv-explorer），在变更
-- 面板里没有意义，也不值得为它去遍历整个工作区

local Tree = require('vv-git.tree')

local M = {}

-- 展示顺序固定，不跟着 pairs 的随机顺序走
local STATUS_LABELS = {
  { letter = 'M', label = 'Modified' },
  { letter = 'A', label = 'Added' },
  { letter = 'D', label = 'Deleted' },
  { letter = 'R', label = 'Renamed' },
  { letter = 'C', label = 'Copied' },
  { letter = '?', label = 'Untracked' },
  { letter = '!', label = 'Conflict' },
}

---@param node table 变更树的目录节点
---@param display_path string
---@return string[]
function M.lines(node, display_path)
  local status = Tree.count_status(node)

  local lines = {
    'Directory',
    '',
    'Path: ' .. display_path,
    ('Changes: %d %s'):format(status.total, status.total == 1 and 'file' or 'files'),
  }

  local rows = {}
  local counted = 0
  for _, entry in ipairs(STATUS_LABELS) do
    local count = status.letters[entry.letter]
    if count then
      counted = counted + count
      rows[#rows + 1] = ('%s: %d'):format(entry.label, count)
    end
  end

  -- 未知状态码也要算进去，否则分项加起来对不上 Changes，看起来像丢了文件
  if counted < status.total then
    rows[#rows + 1] = ('Other: %d'):format(status.total - counted)
  end

  if #rows > 0 then
    lines[#lines + 1] = ''
    vim.list_extend(lines, rows)
  end

  return lines
end

return M
