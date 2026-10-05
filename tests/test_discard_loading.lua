-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['确认后分片删除保持事件循环进展，刷新渲染后释放加载帧'] = function()
  child.lua_func(function()
    -- discard 在途 loading：
    --   1. 确认前不显示帧；取消确认不显示帧
    --   2. 确认后帧盖在被丢弃目录的图标槽，删除期间与随后 reload 渲染前一直保留
    --   3. 未跟踪大目录走分片异步删除：删除期间主线程不被独占
    --   4. 写入后的 reload 渲染完成，帧消失

    local uv = vim.uv
    local State = require('vv-git.state')
    local Tree = require('vv-git.tree')
    local Render = require('vv-git.left.render')
    local Panel = require('vv-git.left.panel')
    local Git = require('vv-git.git')
    local Confirm = require('vv-utils.confirm')
    local Actions = require('vv-git.left.actions')

    local ROOT = vim.fs.normalize(vim.fn.tempname())
    local BIG = ROOT .. '/big'
    vim.fn.mkdir(BIG, 'p')
    for d = 1, 40 do
      vim.fn.mkdir(BIG .. '/d' .. d, 'p')
      for f = 1, 500 do
        local fd = uv.fs_open(BIG .. '/d' .. d .. '/f' .. f, 'w', 420)
        uv.fs_close(fd)
      end
    end
    vim.fn.writefile({ 'x' }, ROOT .. '/keep.txt')

    local INFO = { upstream = 'origin/main', ahead = 0, behind = 0, branch = 'main', branch_name = 'main', head = 'abc', remotes = { 'origin' } }
    local buf = Panel.create_buf()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    State.clear()
    local state = State.create()
    state.git_root = ROOT
    state.panel = { buf = buf, win = win, main_win = win }
    state.folds, state.section_folds, state.selection, state.block_folds = {}, {}, {}, {}
    state.repo_info = INFO
    state.branch = 'main'
    state.tree = Tree.build({ [BIG] = '??', [ROOT .. '/keep.txt'] = '??' }, ROOT)
    Render.render(state)

    local reloads = {}
    Git.index = function(_, cb)
      reloads[#reloads + 1] = cb
      return function() end
    end
    Git.repo_info = function(_, cb) cb(INFO); return function() end end

    -- 确认框：由测试决定确认 / 取消
    local pending_confirm
    Confirm.open = function(opts)
      pending_confirm = opts
      return { close = function() end }
    end

    local function find(relpath)
      for lnum, id in pairs(state.panel.id_by_line) do
        if id.node and id.node.relpath == relpath then return lnum, id end
      end
    end

    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local chunk = mark[4].virt_text and mark[4].virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then result[#result + 1] = { row = mark[2] + 1, col = mark[3] } end
      end
      return result
    end

    local function wait(ms) vim.wait(ms, function() return false end, 5) end

    local big_line, big_id = find('big')
    assert(big_id, '前置：未跟踪目录 big 应出现在面板：' .. vim.inspect(state.panel.id_by_line))

    -- 1：取消确认不显示
    Actions.discard(state, big_id)
    assert(pending_confirm, '应弹出确认框')
    wait(200)
    assert(#loading_marks() == 0, '确认前不得显示帧')
    pending_confirm.on_cancel()
    pending_confirm = nil
    wait(200)
    assert(#loading_marks() == 0 and uv.fs_stat(BIG), '取消后不显示帧、不删除')

    -- 2 + 3：确认后删除期间帧在图标槽，主线程不被独占
    Actions.discard(state, big_id)
    -- 每片强制只处理一个目录 entry，不依赖机器快慢触发让出
    local FS = require('vv-utils.fs')
    local original_delete_async = FS.delete_async
    FS.delete_async = function(target, opts)
      opts.budget_ms = 0
      return original_delete_async(target, opts)
    end
    local ticks_during_delete = 0
    local ticker = uv.new_timer()
    ticker:start(0, 1, vim.schedule_wrap(function()
      if uv.fs_stat(BIG) then ticks_during_delete = ticks_during_delete + 1 end
    end))
    pending_confirm.on_confirm()

    local seen_during_delete = false
    assert(vim.wait(60000, function()
      if uv.fs_stat(BIG) and #loading_marks() == 1 then
        local m = loading_marks()[1]
        seen_during_delete = m.row == big_line and m.col == big_id.icon_col
      end
      return #reloads > 0
    end, 5), '删除完成后应触发 reload')
    ticker:stop(); ticker:close()

    assert(not uv.fs_stat(BIG), '未跟踪目录应被删除')
    assert(uv.fs_stat(ROOT .. '/keep.txt'), '只删除被丢弃的路径')
    assert(seen_during_delete, '删除期间帧应盖在 big 的图标槽')
    assert(ticks_during_delete > 0, '真实目录删除尚未完成时事件循环必须已进展，同步退化不得通过')
    FS.delete_async = original_delete_async
    assert(#loading_marks() == 1, '删除完成、reload 渲染前帧必须保留')

    -- 4
    table.remove(reloads)({ status_map = { [ROOT .. '/keep.txt'] = '??' }, rename_map = {} })
    wait(30)
    assert(#loading_marks() == 0, 'reload 渲染完成后帧必须消失')

    vim.fn.delete(ROOT, 'rf')
  end)
end

return T
