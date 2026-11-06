local T, child = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua').new_set()

local function setup()
  child.lua([[
    vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO .. '/tests/fixtures/inline_diff')
    local Async = require('vv-utils.async')
    local worker_task = Async.worker_task
    jobs, gates, errors = {}, {}, {}
    vim.notify = function(message) errors[#errors + 1] = message end
    Async.worker_task = function(opts)
      local index = #jobs + 1
      local gate = vim.env.VV_TEST_TMP .. '/gate-' .. index
      gates[index] = gate
      local input, done = opts.input, opts.on_done
      opts.worker = 'vv_git_test_inline_worker'
      opts.input = function(i)
        local value = input(i)
        value.test_gate, value.test_error = gate, fail_next
        fail_next = false
        return value
      end
      opts.on_done = function(result)
        jobs[index].done = true
        done(result)
      end
      local task = worker_task(opts)
      jobs[index] = { task = task }
      return task
    end
    api = vim.api
    buf = api.nvim_get_current_buf()
    win = api.nvim_get_current_win()
    base = {}
    for i = 1, 80 do base[i] = 'line ' .. i end
    local changed = vim.deepcopy(base)
    changed[40] = 'changed forty'
    api.nvim_buf_set_lines(buf, 0, -1, false, changed)
    Inline = require('vv-git.inline_diff')
    ns = api.nvim_create_namespace('vv-git-inline-diff')
    navigation = { pending = true }
    ready = 0
    opts = { b_win = win, navigation = navigation, on_initial_ready = function(result)
      ready = ready + 1
      if navigation.pending and result.first_b_line then
        api.nvim_win_set_cursor(win, { result.first_b_line, 0 })
      end
    end }
    function marks() return api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) end
    function wait_for(fn, message) assert(vim.wait(3000, fn, 5), message) end
    function started(i)
      wait_for(function() return vim.uv.fs_stat(gates[i] .. '.started') ~= nil end, '真实 worker 未启动')
    end
    function release(i)
      vim.fn.writefile({ 'go' }, gates[i])
      wait_for(function() return jobs[i].done end, '真实 worker 未完成')
    end
    function change(line, text, event)
      api.nvim_buf_set_lines(buf, line - 1, line, false, { text })
      if event ~= false then api.nvim_exec_autocmds('TextChanged', { buffer = buf }) end
    end
  ]])
end

T['真实线程计算且等待期间主循环推进，主线程禁止 diff 仍成功'] = function()
  setup()
  child.lua([[
    vim.text.diff = function() error('禁止主线程 diff') end
    vim.diff = vim.text.diff
    cleanup = Inline.attach_live(buf, base, 100, opts)
    started(1)
    assert(#marks() == 0, '首帧必须先显示文件而不是同步装饰')
    local ticks = 0
    local timer = vim.uv.new_timer()
    timer:start(1, 1, function() ticks = ticks + 1 end)
    wait_for(function() return ticks >= 3 end, '后台等待不能阻塞主循环')
    timer:stop(); timer:close()
    release(1)
    assert(#marks() > 0 and ready == 1, '后台结果必须应用装饰并通知一次')
    assert(api.nvim_win_get_cursor(win)[1] == 40, '首 hunk 导航必须消费计算结果')
    cleanup()
  ]])
end

T['编辑立即拒绝旧结果且 debounce 与实际在途共同限制重算'] = function()
  setup()
  child.lua([[
    cleanup = Inline.attach_live(buf, base, 100, opts)
    started(1)
    change(40, 'new forty')
    release(1)
    assert(#marks() == 0 and ready == 0, 'debounce 前抵达的旧结果不得发布')
    assert(#jobs == 1, '首次编辑不得跳过200ms防抖')
    wait_for(function() return #jobs == 2 end, '末次内容必须重算')
    started(2)
    for i = 1, 5 do change(40, 'last ' .. i) end
    vim.wait(250)
    assert(#jobs == 2, '旧 work 实际完成前不得新建控制器绕过并发限制')
    release(2)
    wait_for(function() return #jobs == 3 end, '真实完成后必须补一次最新 dirty')
    started(3); release(3)
    assert(#marks() > 0 and #jobs == 3, '最后结果不能丢失或重复调度')
    assert(api.nvim_win_get_cursor(win)[1] == 1, '编辑必须撤销首次导航')
    cleanup()
  ]])
end

T['changedtick 尚无事件也拒绝结果，关闭重开同 buffer 不被旧 cleanup 清除'] = function()
  setup()
  child.lua([[
    cleanup = Inline.attach_live(buf, base, 100, opts)
    started(1)
    change(40, 'without event', false)
    release(1)
    assert(#marks() == 0 and ready == 0, 'changedtick 是事件之外的发布守卫')
    cleanup()
    local old = cleanup
    cleanup = Inline.attach_live(buf, base, 100, opts)
    started(2)
    old(); old()
    release(2)
    assert(#marks() > 0, '旧 cleanup 不得影响同 buffer 新 owner')
    change(40, 'closing')
    wait_for(function() return #jobs == 3 end, '关闭场景必须有真实在途 work')
    started(3)
    cleanup()
    vim.fn.writefile({ 'go' }, gates[3])
    wait_for(function() return vim.uv.fs_stat(gates[3] .. '.finished') ~= nil end, '取消后物理 work 仍应结束')
    vim.wait(30)
    assert(#marks() == 0, '关闭后迟到结果不能重建装饰')
  ]])
end

T['live 等待保留旧装饰，失败清除标记和折叠并报告错误'] = function()
  setup()
  child.lua([[
    cleanup = Inline.attach_live(buf, base, 100, opts)
    started(1); release(1)
    local count = #marks()
    assert(count > 0, '必须先有可见旧装饰')
    fail_next = true
    change(40, 'will fail')
    wait_for(function() return #jobs == 2 end, '失败请求必须启动')
    started(2)
    assert(#marks() == count, '重算等待期必须保留旧装饰')
    release(2)
    assert(#marks() == 0 and #errors == 1 and errors[1]:find('测试计算失败'), '失败必须清旧并报错，不得同步回退')
    assert(vim.fn.foldclosed(70) == -1, '失败不能保留旧折叠')
    cleanup()
  ]])
end

for _, action in ipairs({ 'cursor', 'scroll', 'enter' }) do
  T['用户接管取消导航且折叠保持回调时视口：' .. action] = function()
    setup()
    child.lua_func(function(kind)
      cleanup = Inline.apply_async(buf, base, 100, opts)
      started(1)
      if kind == 'cursor' then
        api.nvim_win_set_cursor(win, { 20, 0 })
        api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
        api.nvim_win_set_cursor(win, { 1, 0 })
      elseif kind == 'scroll' then
        -- 光标在变更行，视口顶部在将形成的另一个折叠内，不能只展开光标所在折叠
        vim.wo[win].wrap = false
        vim.fn.winrestview({ lnum = 40, col = 8, curswant = 8, topline = 20, leftcol = 3 })
        api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(win) })
      else
        vim.cmd('vsplit')
        api.nvim_set_current_win(win)
      end
      local saved = vim.fn.winsaveview()
      release(1)
      assert(not navigation.pending, '用户接管必须取消导航')
      local after = vim.fn.winsaveview()
      assert(after.lnum == saved.lnum and after.topline == saved.topline,
        '异步折叠不得改变回调时光标或滚动位置：' .. vim.inspect({ before = saved, after = after }))
      assert(after.col == saved.col and after.curswant == saved.curswant and after.leftcol == saved.leftcol,
        '定点展开折叠不得改变当前列、期望列或横滚')
      if kind == 'scroll' then
        assert(vim.fn.foldclosed(20) == -1, '视口顶部所在折叠必须展开')
        assert(vim.fn.foldclosed(70) == 47, '视口外47..80折叠必须保持闭合，不能清空全部折叠')
      end
      cleanup()
    end, action)
  end
end

T['max 边界和禁折叠在派发前生效'] = function()
  setup()
  child.lua([[
    for _, limit in ipairs({ 79, 80, 81 }) do
      local previous = #jobs
      opts.fold_unchanged = false
      vim.wo.foldenable = true
      cleanup = Inline.apply_async(buf, base, limit, opts)
      assert(not vim.wo.foldenable, '禁折叠不应等待 worker，包括超限分支')
      if limit < 80 then
        assert(#jobs == previous and #marks() == 0, '超过 max 才跳过且不得派发')
      else
        started(previous + 1); release(previous + 1)
        assert(#marks() > 0, '等于 max 仍须计算')
      end
      cleanup()
    end
  ]])
end

T['owner 失效或窗口换 buffer 后迟到结果不得发布'] = function()
  setup()
  child.lua([[
    local valid = true
    opts.is_valid = function() return valid end
    cleanup = Inline.apply_async(buf, base, 100, opts)
    started(1); valid = false; release(1)
    assert(#marks() == 0 and ready == 0, '失效 owner 不得发布')
    cleanup()
    valid = true
    cleanup = Inline.apply_async(buf, base, 100, opts)
    started(2)
    api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
    release(2)
    assert(#marks() == 0 and ready == 0, '窗口已换 buffer 不得发布')
    cleanup()
  ]])
end

T['旧 debounce 已排队回调不得越过新编辑的尾沿'] = function()
  setup()
  child.lua([[
    local queued = {}
    require('vv-utils.timer').debounce = function(callback)
      return function(version)
        queued[#queued + 1] = function() callback(version) end
      end, function() end
    end
    cleanup = Inline.attach_live(buf, base, 100, opts)
    started(1); release(1)
    change(40, 'first edit')
    change(40, 'latest edit')
    queued[1]()
    assert(#jobs == 1, '旧 timer 的 scheduled callback 不得提前启动末次编辑')
    queued[2]()
    assert(#jobs == 2, '只有最新尾沿能启动重算')
    started(2); release(2)
    cleanup()
  ]])
end

T['关闭后同 buffer 重开，旧 work 物理完成不得清除后继装饰'] = function()
  setup()
  child.lua([[
    local old_cleanup = Inline.attach_live(buf, base, 100, opts)
    started(1)
    old_cleanup()
    cleanup = Inline.attach_live(buf, base, 100, opts)
    started(2); release(2)
    local current = marks()
    assert(#current > 0, '新 owner 必须先渲染完成')
    vim.fn.writefile({ 'go' }, gates[1])
    wait_for(function() return vim.uv.fs_stat(gates[1] .. '.finished') ~= nil end, '取消的旧 work 必须真实结束')
    vim.wait(30)
    old_cleanup()
    assert(vim.deep_equal(marks(), current), '旧完成或重复 cleanup 不得破坏后继 owner')
    cleanup()
  ]])
end

return T
