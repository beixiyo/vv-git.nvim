-- 全局单例状态（仿 diffview 的"专属 tabpage"模型，一次只能有一个 vv-git 视图）
--
-- state.tabpage   = vv-git 独占的 tabpage id
-- state.prev_tab  = 打开 vv-git 前用户所在的 tabpage（关闭时回跳）
-- state.panel     = 左栏 panel 表（{ buf, win, main_win }）
-- state.view      = 右栏 diff 视图表（{ a_win, b_win, a_buf, b_buf, path, mode='diff2'|'single' }）
-- state.git_root  = 父仓库根绝对路径
-- state.index     = 父仓库 index 视图：{ status_map, rename_map }（形状与子仓库一致）
-- state.branch    = 父仓库当前分支名（detached 时为短 hash）；header 行显示 󰘬 <branch>
-- state.tree      = 父仓库变更树：{ staged, unstaged, conflicts }
-- state.subrepos  = 发现的子仓库块列表：{ { root, label, tree, index }, ... }（depth>0 时）
--                   每个子仓库各建一棵独立树，在左栏作为「Sub-Repo: <label>」块渲染
-- state._subrepo  = 子仓库扫描配置注入（lifecycle 在 open 时填）：{ depth():integer, config():table }
-- state.folds         = { ['<section_id>\0<relpath>'] = true }  被折叠的文件夹集合
-- state.section_folds = { [section_id] = true }  被折叠的 section
--                   section_id：父仓库为裸 base（staged/unstaged/conflicts），
--                   子仓库为 `<root>\0<base>`（见 vv-git.subrepo）。key 拼/拆统一走
--                   Subrepo.sel_key / split_key / parse_sel_key，分隔符全用 NUL（按仓库隔离）
-- state.block_folds = { [repo_root] = true }  被折叠的整个仓库块（根仓库 state.git_root / 子仓库根；只留标题行）
-- state.selection = { ['<section_id>\0<relpath>'] = true }  多选集合（仅文件节点）
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
      subrepos = {},
      folds = {},
      section_folds = {},
      block_folds = {},
      selection = {},
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
