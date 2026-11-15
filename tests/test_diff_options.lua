-- diff 视图依赖的全局选项只在 diff 窗口存在期间生效
-- 走生产的 View.show / View.close，只替换 revision 取数
local T, child = dofile('tests/helpers.lua').new_set()

local function setup()
  child.lua_func(function()
    local api = vim.api
    vim.o.columns, vim.o.lines = 220, 60
    original = {
      diffopt = 'internal,filler,closeoff,context:6',
      scrollopt = 'ver,jump',
      fillchars = 'eob:~',
    }
    for name, value in pairs(original) do vim.go[name] = value end

    local root = vim.env.VV_TEST_TMP
    vim.fn.writefile({ 'one', 'changed', 'three' }, root .. '/a.txt')
    require('vv-git').setup({ auto_refresh = false, preview = false, diff_fill = '.',
      worktree_preview = 'snapshot', snapshot_promote_ms = false })
    require('vv-git.git').show = function(_, _, _, callback) callback({ 'one', 'two', 'three' }) end

    local main = api.nvim_get_current_win()
    vim.cmd('leftabove vsplit')
    state = { git_root = root, tabpage = api.nvim_get_current_tabpage(),
      panel = { win = api.nvim_get_current_win(), main_win = main } }
    View = require('vv-git.right.view')
    function show()
      View.show(state, { relpath = 'a.txt', xy = ' M' }, 'unstaged', false, root)
      assert(state.view, '生产入口必须真实挂载视图')
    end
    function current()
      return { diffopt = vim.go.diffopt, scrollopt = vim.go.scrollopt, fillchars = vim.go.fillchars }
    end
    function settle() vim.wait(200, function() return false end, 10) end
  end)
end

T['setup 不改全局选项，打开 diff 时接管，关闭后还原'] = function()
  setup()
  child.lua_func(function()
    assert(vim.deep_equal(current(), original), 'setup 之后：' .. vim.inspect(current()))

    show()
    local held = current()
    assert(held.diffopt:find('linematch:60', 1, true) and held.diffopt:find('inline:char', 1, true), held.diffopt)
    assert(held.scrollopt:find('hor', 1, true), held.scrollopt)
    assert(held.fillchars:find('diff:.', 1, true), held.fillchars)

    View.close(state)
    settle()
    assert(vim.deep_equal(current(), original), '关闭之后：' .. vim.inspect(current()))
  end)
end

T['接管期间被外部改过的选项保持现值'] = function()
  setup()
  child.lua_func(function()
    show()
    vim.go.diffopt = 'internal,filler,context:3'

    View.close(state)
    settle()
    assert(vim.go.diffopt == 'internal,filler,context:3', vim.go.diffopt)
    assert(vim.go.scrollopt == original.scrollopt, vim.go.scrollopt)
    assert(vim.go.fillchars == original.fillchars, vim.go.fillchars)
  end)
end

return T
