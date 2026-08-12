-- right/plan.lua 的纯 section/status/宽度路由契约
-- Run: nvim --headless -u NONE -l tests/test_plan.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local Plan = require('vv-git.right.plan')

local function resolve(overrides)
  return Plan.resolve(vim.tbl_extend('force', {
    section = 'staged',
    xy = 'M ',
    force_single = false,
    from_rev = 'from',
    to_rev = 'to',
    relpath = 'new.lua',
    old_relpath = 'old.lua',
  }, overrides))
end

local function assert_plan(label, overrides, expected)
  local actual = resolve(overrides)
  assert(vim.deep_equal(actual, expected), string.format(
    '%s\nexpected: %s\nactual: %s',
    label,
    vim.inspect(expected),
    vim.inspect(actual)
  ))
end

assert_plan('暂存区新增应天然是单窗口', { xy = 'A ' }, {
  kind = 'single_rev',
  rev = ':0',
  path = 'new.lua',
  side = 'new',
  intrinsic_single = true,
})
assert_plan('窄屏下暂存区删除应天然是单窗口', {
  xy = 'D ',
  force_single = true,
}, {
  kind = 'single_rev',
  rev = 'HEAD',
  path = 'new.lua',
  side = 'old',
  intrinsic_single = true,
})
assert_plan('暂存区修改在宽屏下应使用双修订窗口方案', {}, {
  kind = 'dual_rev_rev',
  a_rev = 'HEAD',
  b_rev = ':0',
  a_path = 'new.lua',
  b_path = 'new.lua',
  fallback = 'staged',
  intrinsic_single = false,
})
assert_plan('暂存区修改在窄屏下应使用行内方案', { force_single = true }, {
  kind = 'single_rev_inline',
  a_rev = 'HEAD',
  b_rev = ':0',
  a_path = 'new.lua',
  b_path = 'new.lua',
  fetch_mode = 'parallel',
  intrinsic_single = false,
})

assert_plan('未暂存新增应天然是单窗口', {
  section = 'unstaged',
  xy = '??',
}, {
  kind = 'single_worktree',
  path = 'new.lua',
  intrinsic_single = true,
})
assert_plan('窄屏下未暂存删除应天然是单窗口', {
  section = 'unstaged',
  xy = ' D',
  force_single = true,
}, {
  kind = 'single_rev',
  rev = ':0',
  path = 'new.lua',
  side = 'old',
  intrinsic_single = true,
})
assert_plan('未暂存修改在宽屏下应使用修订-工作树方案', {
  section = 'unstaged',
}, {
  kind = 'dual_rev_worktree',
  a_rev = ':0',
  a_path = 'new.lua',
  path = 'new.lua',
  intrinsic_single = false,
})
assert_plan('未暂存修改在窄屏下应使用工作树行内方案', {
  section = 'unstaged',
  force_single = true,
}, {
  kind = 'single_worktree_inline',
  a_rev = ':0',
  a_path = 'new.lua',
  path = 'new.lua',
  intrinsic_single = false,
})

assert_plan('宽屏比较重命名应保留新旧路径', {
  section = 'compare',
  compare_status = 'R',
}, {
  kind = 'dual_rev_rev',
  a_rev = 'from',
  b_rev = 'to',
  a_path = 'old.lua',
  b_path = 'new.lua',
  fallback = 'compare',
  intrinsic_single = false,
})
assert_plan('窄屏比较重命名应保留新旧路径', {
  section = 'compare',
  compare_status = 'R',
  force_single = true,
}, {
  kind = 'single_rev_inline',
  a_rev = 'from',
  b_rev = 'to',
  a_path = 'old.lua',
  b_path = 'new.lua',
  fetch_mode = 'serial',
  intrinsic_single = false,
})
assert_plan('比较新增应仅显示目标修订', {
  section = 'compare',
  compare_status = 'A',
}, {
  kind = 'single_rev',
  rev = 'to',
  path = 'new.lua',
  side = 'new',
  intrinsic_single = true,
})
assert_plan('比较删除应显示来源修订中的旧路径', {
  section = 'compare',
  compare_status = 'D',
}, {
  kind = 'single_rev',
  rev = 'from',
  path = 'old.lua',
  side = 'old',
  intrinsic_single = true,
})

assert_plan('宽屏冲突应使用三窗方案', {
  section = 'conflicts',
}, {
  kind = 'conflict3',
  a_rev = ':2',
  b_rev = ':3',
  a_path = 'new.lua',
  b_path = 'new.lua',
  intrinsic_single = false,
})
assert_plan('窄屏冲突应使用行内 ours-theirs 方案', {
  section = 'conflicts',
  force_single = true,
}, {
  kind = 'single_rev_inline',
  a_rev = ':2',
  b_rev = ':3',
  a_path = 'new.lua',
  b_path = 'new.lua',
  fetch_mode = 'parallel',
  intrinsic_single = false,
})

print('PASS: vv-git 右侧 plan 路由回归')
