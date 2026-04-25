-- 全局单例状态（仿 diffview 的"专属 tabpage"模型，一次只能有一个 vv-git 视图）
--
-- state.tabpage   = vv-git 独占的 tabpage id
-- state.prev_tab  = 打开 vv-git 前用户所在的 tabpage（关闭时回跳）
-- state.panel     = 左栏 panel 表（{ buf, win, main_win }）
-- state.view      = 右栏 diff 视图表（{ a_win, b_win, a_buf, b_buf, path, mode='diff2'|'single' }）
-- state.git_root  = 当前仓库根绝对路径
-- state.index     = vv-utils.git.index() 返回的 { status_map, is_ignored }
-- state.tree      = 变更树：{ staged, unstaged, conflicts }
-- state.folds     = { [relpath] = true }  被折叠的文件夹集合
-- state.cur_path  = 当前选中文件相对路径

local M = {}

---@type table?
M._state = nil

---@return boolean
function M.has() return M._state ~= nil end

---@return table
function M.get()
  if not M._state then
    M._state = {
      tabpage = nil,
      prev_tab = nil,
      panel = nil,
      view = nil,
      git_root = nil,
      index = nil,
      tree = nil,
      folds = {},
      cur_path = nil,
    }
  end
  return M._state
end

function M.clear() M._state = nil end

-- 把「需要 state 存在才执行」的函数包一层：state 为空时直接短路；
-- 否则把 state 作为第一参数传入，其余参数透传（autocmd 的 args / 普通调用的 ...）
---@generic T
---@param fn fun(state:table, ...):T
---@return fun(...):T?
function M.guarded(fn)
  return function(...)
    if not M._state then return end
    return fn(M._state, ...)
  end
end

return M
