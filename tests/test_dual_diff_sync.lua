-- 只替换 revision 取数，生产 show / options / 原生 diff / 调度均保留
-- 同一 RPC 内挂载并制造竞态，排队回调直到 drain 才执行，避免依赖计时碰运气
local T, child = dofile('tests/helpers.lua').new_set()

local function setup()
  child.lua_func(function()
    local api = vim.api
    vim.o.columns, vim.o.lines = 220, 60
    vim.o.diffopt = 'internal,filler,closeoff,context:6'
    local root = vim.env.VV_TEST_TMP
    base, changed = {}, {}
    for i = 1, 120 do base[i], changed[i] = 'line ' .. i, 'line ' .. i end
    changed[40], changed[90] = 'changed forty', 'changed ninety'
    for _, path in ipairs({ 'a.txt', 'b.txt' }) do vim.fn.writefile(changed, root .. '/' .. path) end
    require('vv-git').setup({ auto_refresh = false, preview = false,
      worktree_preview = 'snapshot', snapshot_promote_ms = false })
    require('vv-git.git').show = function(_, rev, _, callback)
      callback(rev == ':3' and changed or base)
    end
    local main = api.nvim_get_current_win()
    vim.cmd('leftabove vsplit')
    state = { git_root = root, tabpage = api.nvim_get_current_tabpage(),
      panel = { win = api.nvim_get_current_win(), main_win = main } }
    View = require('vv-git.right.view')
    function show(path, conflict)
      View.show(state, { relpath = path or 'a.txt', xy = conflict and 'UU' or ' M' },
        conflict and 'conflicts' or 'unstaged', false, root)
      assert(state.view, '生产入口必须真实挂载视图')
      return state.view
    end
    function observe()
      refreshes, folds, events = 0, 0, {}
      local command, in_refresh = vim.cmd, false
      vim.cmd = function(cmd)
        if cmd == 'diffupdate' then refreshes = refreshes + 1; in_refresh = true end
        if cmd == 'normal! zX' then folds = folds + 1 end
        local ok, err = pcall(command, cmd)
        in_refresh = false
        if not ok then error(err) end
      end
      api.nvim_create_autocmd('DiffUpdated', { callback = function()
        if in_refresh then events[#events + 1] = api.nvim_get_current_tabpage() end
      end })
    end
    function drain()
      local done = false
      vim.schedule(function() done = true end)
      assert(vim.wait(1000, function() return done end, 5), '调度必须排空')
    end
    function no_refresh()
      drain()
      assert(refreshes == 0 and folds == 0,
        ('过期目标不得执行 diffupdate/zX，实际 %d/%d'):format(refreshes, folds))
      assert(#events == 0, '过期目标不得触发显式原生 DiffUpdated')
    end
  end)
end

for _, reason in ipairs({ 'wipe', 'buffer', 'request', 'root-aba', 'closing', 'view', 'tab', 'close', 'result' }) do
  T['重活前拒绝失效目标：' .. reason] = function()
    setup()
    child.lua_func(function(cause)
      local api = vim.api
      local view = show(nil, cause == 'result')
      if cause == 'wipe' then
        api.nvim_buf_delete(view.a_buf, { force = true })
      elseif cause == 'buffer' then
        vim.bo[view.b_buf].bufhidden = 'hide'
        api.nvim_win_set_buf(view.b_win, api.nvim_create_buf(false, true))
        assert(api.nvim_buf_is_valid(view.b_buf), '须覆盖旧 buffer 仍有效但不再属于窗口')
      elseif cause == 'request' then
        -- 下次取数尚未完成，旧 view 仍显示，不能刷新旧 request
        require('vv-git.git').show = function() end
        View.show(state, { relpath = 'b.txt', xy = ' M' }, 'unstaged')
      elseif cause == 'root-aba' then
        local State, root = require('vv-git.state'), state.git_root
        State.set_root(state, root .. '/other'); State.set_root(state, root)
      elseif cause == 'closing' then
        state._closing = true
      elseif cause == 'view' then
        state.view = vim.tbl_extend('force', {}, view)
      elseif cause == 'tab' then
        vim.cmd('tabnew')
        state.tabpage = api.nvim_get_current_tabpage()
      elseif cause == 'close' then
        View.close(state)
      elseif cause == 'result' then
        api.nvim_win_set_buf(view.c_win, api.nvim_create_buf(false, true))
      end
      observe()
      no_refresh()
    end, reason)
  end
end

T['快速切文件合并同 owner 待执行刷新且最后文件首 hunk 不丢'] = function()
  setup()
  child.lua_func(function()
    local old = show()
    show('b.txt')
    local newest = show('b.txt')
    assert(not vim.api.nvim_buf_is_valid(old.a_buf), '真实替换必须 wipe 旧 scratch')
    observe(); drain()
    assert(refreshes == 1 and folds == 2, '同 owner 待执行刷新应只执行最新一次：' .. refreshes .. '/' .. folds)
    assert(#events == 1 and events[1] == state.tabpage, '必须由所属 tab 的原生 diff 完成刷新')
    assert(vim.api.nvim_win_get_cursor(newest.a_win)[1] == 40, '最新文件必须定位首 hunk')
    assert(vim.api.nvim_win_get_cursor(newest.b_win)[1] == 40, '两侧首 hunk 必须一致')
  end)
end

T['切到其它 diff tab 后只刷新 owner 且不遗漏后台首 hunk'] = function()
  setup()
  child.lua_func(function()
    local api = vim.api
    local view = show()
    vim.cmd('tabnew')
    local other_tab = api.nvim_get_current_tabpage()
    api.nvim_buf_set_lines(0, 0, -1, false, { 'other', 'old' })
    vim.cmd('diffthis | vnew')
    api.nvim_buf_set_lines(0, 0, -1, false, { 'other', 'new' })
    vim.cmd('diffthis | diffupdate')
    local other_win = api.nvim_get_current_win()
    api.nvim_win_set_cursor(other_win, { 2, 0 })
    observe(); drain()
    assert(#events == 1 and events[1] == state.tabpage,
      '显式 DiffUpdated 必须属于 owner 而非用户当前 tab：' .. vim.inspect(events))
    assert(api.nvim_get_current_tabpage() == other_tab and api.nvim_get_current_win() == other_win,
      '后台初始化不得抢焦点')
    assert(api.nvim_win_get_cursor(other_win)[1] == 2, '不得移动其它 tab 光标')
    assert(api.nvim_win_get_cursor(view.a_win)[1] == 40, '切 tab 不能丢失合法首 hunk 初始化')
  end)
end

T['close 后重开创建新 owner 调度且旧回调不复活'] = function()
  setup()
  child.lua_func(function()
    show(); View.close(state)
    local view = show('b.txt')
    observe(); drain()
    assert(refreshes == 1 and folds == 2, 'close 后只允许新 owner 刷新')
    assert(vim.api.nvim_win_get_cursor(view.b_win)[1] == 40, '重开首 hunk 必须完成')
  end)
end

T['DiffUpdated 同步关闭后不得继续折叠或导航'] = function()
  setup()
  child.lua_func(function()
    show(); observe()
    vim.api.nvim_create_autocmd('DiffUpdated', { once = true, callback = function() View.close(state) end })
    drain()
    assert(refreshes == 1 and folds == 0, '重入关闭后不得继续 zX：' .. folds)
    assert(state.view == nil, '关闭不能被旧回调复活')
  end)
end

T['三栏保留原生首 hunk 与 Result 非 diff 滚动绑定'] = function()
  setup()
  child.lua_func(function()
    local api = vim.api
    local view = show(nil, true)
    observe(); drain()
    assert(view.mode == 'conflict3', '冲突必须保持三栏')
    assert(refreshes == 1 and #events == 1, '三栏必须共享一次原生刷新')
    for _, win in ipairs({ view.a_win, view.b_win, view.c_win }) do
      if win ~= view.c_win then
        assert(api.nvim_win_get_cursor(win)[1] == 40, '上方原生 diff 必须定位首 hunk')
      end
      assert(vim.wo[win].scrollbind, '三栏必须保留 scrollbind')
    end
    assert(not vim.wo[view.c_win].diff, 'Result 不能变成第三个原生 diff 输入')
  end)
end

T['双栏折叠与面板驱动第一次滚动继续同步'] = function()
  setup()
  child.lua_func(function()
    local api = vim.api
    local view = show()
    drain()
    assert(api.nvim_win_call(view.a_win, function() return vim.fn.foldclosed(1) end) == 1,
      '未变部分必须保持原生 diff 折叠')
    for _, win in ipairs({ view.a_win, view.b_win }) do
      api.nvim_win_call(win, function() vim.cmd('normal! zR') end)
    end
    local function top(win) return api.nvim_win_call(win, function() return vim.fn.line('w0') end) end
    local before = top(view.a_win)
    api.nvim_win_call(view.b_win, function() vim.cmd('normal! 3\5') end)
    assert(top(view.a_win) > before and top(view.a_win) == top(view.b_win),
      '面板驱动的第一次滚动必须同步，不能被 did_syncbind 吞掉')
    assert(api.nvim_get_current_win() == state.panel.win, '滚动不得转移面板焦点')
  end)
end

T['初始化排队期间 promote 保留必要原生刷新且旧快照不再重算'] = function()
  setup()
  child.lua_func(function()
    local api = vim.api
    local view = show()
    local snapshot = view.b_buf
    api.nvim_win_set_cursor(view.b_win, { 25, 0 })
    observe()
    assert(View.promote(state), '真实 snapshot 必须能 promote')
    assert(not api.nvim_buf_is_valid(snapshot), 'promote 必须释放旧快照')
    assert(refreshes == 1 and #events == 1, 'promote 必须保留自己的同步 diffupdate')
    local cursor = api.nvim_win_get_cursor(view.b_win)
    drain()
    assert(refreshes == 1 and folds == 0, '快照旧初始化不能再刷新真实 buffer')
    assert(vim.deep_equal(api.nvim_win_get_cursor(view.b_win), cursor), '旧初始化不得覆盖 promote 保留的光标')
  end)
end

return T
