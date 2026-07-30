-- 右侧 diff 的纯路由计划：把 section/status/宽度决策转换为声明式执行计划

local M = {}

---@class VVGitRightPlanInput
---@field section 'staged'|'unstaged'|'compare'|'conflicts'
---@field xy string
---@field compare_status string?
---@field force_single boolean
---@field from_rev string?
---@field to_rev string?
---@field relpath string
---@field old_relpath string?

---@class VVGitRightPlan
---@field kind 'single_rev'|'single_worktree'|'single_rev_inline'|'single_worktree_inline'|'dual_rev_rev'|'dual_rev_worktree'|'conflict3'
---@field intrinsic_single boolean
---@field rev? string
---@field a_rev? string
---@field b_rev? string
---@field path? string
---@field a_path? string
---@field b_path? string
---@field fallback? 'staged'|'compare'
---@field fetch_mode? 'parallel'|'serial'
---@field side? 'new'|'old'

---@param input VVGitRightPlanInput
---@return VVGitRightPlan?
function M.resolve(input)
  local section = input.section
  local xy = input.xy

  if section == 'staged' then
    local index_status = xy:sub(1, 1)
    if index_status == 'A' or xy == '??' then
      return {
        kind = 'single_rev',
        rev = ':0',
        path = input.relpath,
        side = 'new',
        intrinsic_single = true,
      }
    elseif index_status == 'D' then
      return {
        kind = 'single_rev',
        rev = 'HEAD',
        path = input.relpath,
        side = 'old',
        intrinsic_single = true,
      }
    elseif input.force_single then
      return {
        kind = 'single_rev_inline',
        a_rev = 'HEAD',
        b_rev = ':0',
        a_path = input.relpath,
        b_path = input.relpath,
        fetch_mode = 'parallel',
        intrinsic_single = false,
      }
    end
    return {
      kind = 'dual_rev_rev',
      a_rev = 'HEAD',
      b_rev = ':0',
      a_path = input.relpath,
      b_path = input.relpath,
      fallback = 'staged',
      intrinsic_single = false,
    }
  end

  if section == 'unstaged' then
    if xy == '??' then
      return {
        kind = 'single_worktree',
        path = input.relpath,
        intrinsic_single = true,
      }
    elseif xy:sub(2, 2) == 'D' then
      return {
        kind = 'single_rev',
        rev = ':0',
        path = input.relpath,
        side = 'old',
        intrinsic_single = true,
      }
    elseif input.force_single then
      return {
        kind = 'single_worktree_inline',
        a_rev = ':0',
        a_path = input.relpath,
        path = input.relpath,
        intrinsic_single = false,
      }
    end
    return {
      kind = 'dual_rev_worktree',
      a_rev = ':0',
      a_path = input.relpath,
      path = input.relpath,
      intrinsic_single = false,
    }
  end

  if section == 'compare' then
    if not input.from_rev or not input.to_rev then return nil end
    local compare_status = input.compare_status or 'M'
    local old_path = input.old_relpath or input.relpath
    if compare_status == 'A' then
      return {
        kind = 'single_rev',
        rev = input.to_rev,
        path = input.relpath,
        side = 'new',
        intrinsic_single = true,
      }
    elseif compare_status == 'D' then
      return {
        kind = 'single_rev',
        rev = input.from_rev,
        path = old_path,
        side = 'old',
        intrinsic_single = true,
      }
    elseif input.force_single then
      return {
        kind = 'single_rev_inline',
        a_rev = input.from_rev,
        b_rev = input.to_rev,
        a_path = old_path,
        b_path = input.relpath,
        fetch_mode = 'serial',
        intrinsic_single = false,
      }
    end
    return {
      kind = 'dual_rev_rev',
      a_rev = input.from_rev,
      b_rev = input.to_rev,
      a_path = old_path,
      b_path = input.relpath,
      fallback = 'compare',
      intrinsic_single = false,
    }
  end

  if section == 'conflicts' then
    if input.force_single then
      return {
        kind = 'single_rev_inline',
        a_rev = ':2',
        b_rev = ':3',
        a_path = input.relpath,
        b_path = input.relpath,
        fetch_mode = 'parallel',
        intrinsic_single = false,
      }
    end
    return {
      kind = 'conflict3',
      a_rev = ':2',
      b_rev = ':3',
      a_path = input.relpath,
      b_path = input.relpath,
      intrinsic_single = false,
    }
  end

  return nil
end

return M
