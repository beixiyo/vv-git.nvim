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

assert_plan('staged add stays intrinsically single', { xy = 'A ' }, {
  kind = 'single_rev',
  rev = ':0',
  path = 'new.lua',
  side = 'new',
  intrinsic_single = true,
})
assert_plan('staged delete stays intrinsically single on narrow screens', {
  xy = 'D ',
  force_single = true,
}, {
  kind = 'single_rev',
  rev = 'HEAD',
  path = 'new.lua',
  side = 'old',
  intrinsic_single = true,
})
assert_plan('staged modification uses a wide dual revision plan', {}, {
  kind = 'dual_rev_rev',
  a_rev = 'HEAD',
  b_rev = ':0',
  a_path = 'new.lua',
  b_path = 'new.lua',
  fallback = 'staged',
  intrinsic_single = false,
})
assert_plan('staged modification uses a narrow inline plan', { force_single = true }, {
  kind = 'single_rev_inline',
  a_rev = 'HEAD',
  b_rev = ':0',
  a_path = 'new.lua',
  b_path = 'new.lua',
  fetch_mode = 'parallel',
  intrinsic_single = false,
})

assert_plan('unstaged add stays intrinsically single', {
  section = 'unstaged',
  xy = '??',
}, {
  kind = 'single_worktree',
  path = 'new.lua',
  intrinsic_single = true,
})
assert_plan('unstaged delete stays intrinsically single on narrow screens', {
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
assert_plan('unstaged modification uses a wide revision-worktree plan', {
  section = 'unstaged',
}, {
  kind = 'dual_rev_worktree',
  a_rev = ':0',
  a_path = 'new.lua',
  path = 'new.lua',
  intrinsic_single = false,
})
assert_plan('unstaged modification uses a narrow worktree inline plan', {
  section = 'unstaged',
  force_single = true,
}, {
  kind = 'single_worktree_inline',
  a_rev = ':0',
  a_path = 'new.lua',
  path = 'new.lua',
  intrinsic_single = false,
})

assert_plan('wide compare rename keeps old and new paths', {
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
assert_plan('narrow compare rename keeps old and new paths', {
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
assert_plan('compare add displays only the target revision', {
  section = 'compare',
  compare_status = 'A',
}, {
  kind = 'single_rev',
  rev = 'to',
  path = 'new.lua',
  side = 'new',
  intrinsic_single = true,
})
assert_plan('compare delete displays the old path from the source revision', {
  section = 'compare',
  compare_status = 'D',
}, {
  kind = 'single_rev',
  rev = 'from',
  path = 'old.lua',
  side = 'old',
  intrinsic_single = true,
})

assert_plan('wide conflict uses a three-window plan', {
  section = 'conflicts',
}, {
  kind = 'conflict3',
  a_rev = ':2',
  b_rev = ':3',
  a_path = 'new.lua',
  b_path = 'new.lua',
  intrinsic_single = false,
})
assert_plan('narrow conflict uses an inline ours-theirs plan', {
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

print('vv-git right plan routing: PASS')
