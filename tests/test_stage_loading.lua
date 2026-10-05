-- 暂存请求的三条独立生命周期，每条都重新建立模块与面板。
local T, child = dofile('tests/helpers.lua').new_set()

T['暂存完成后的加载帧保持到写后刷新渲染'] = function()
  child.lua_func(function()
    -- stage / unstage 在途 loading：
    --   1. 帧盖在被操作文件的图标槽（overlay），不在行尾
    --   2. Git 写入完成后、reload 渲染前帧保留（文件仍在旧分组，此时停掉看起来像没生效）
    --   3. 写入完成后发起的 reload 渲染完成，帧消失
    --   4. 写入完成「之前」就发起的 reload 结束时不得清掉帧（它的结果不含这次写入）
    --   5. 写入失败帧立即消失

    local State = require('vv-git.state')
    local Tree = require('vv-git.tree')
    local Render = require('vv-git.left.render')
    local Panel = require('vv-git.left.panel')
    local Git = require('vv-git.git')
    local Loader = require('vv-git.loader')
    local Actions = require('vv-git.left.actions')

    local ROOT = '/tmp/vv-git-stage-loading-fake'
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

    local status = {
      [ROOT .. '/src/a.ts'] = ' M',
      [ROOT .. '/src/b.ts'] = ' M',
      [ROOT .. '/src/c.ts'] = ' M',
    }
    state.tree = Tree.build(status, ROOT)
    Render.render(state)

    -- Git 写入与 reload 全部挂起，由测试决定完成时机
    local writes, reloads = {}, {}
    Git.stage = function(_, paths, cb) writes[#writes + 1] = { paths = paths, cb = cb } end
    Git.unstage = Git.stage
    Git.index = function(_, cb)
      reloads[#reloads + 1] = cb
      return function() end
    end
    Git.repo_info = function(_, cb) cb(INFO); return function() end end
    local notify = vim.notify
    vim.notify = function() end

    local function line_of(relpath, base)
      for lnum, id in pairs(state.panel.id_by_line) do
        if id.node and id.node.relpath == relpath and id.base == base then return lnum, id end
      end
    end

    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local chunk = mark[4].virt_text and mark[4].virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then
          result[#result + 1] = { row = mark[2] + 1, col = mark[3], pos = mark[4].virt_text_pos }
        end
      end
      return result
    end

    local function wait(ms) vim.wait(ms, function() return false end, 10) end

    --- 完成最近一次 reload，用给定状态重建树
    local function finish_reload(map)
      local cb = table.remove(reloads)
      assert(cb, '应有一个在途 reload')
      cb({ status_map = map, rename_map = {} })
      wait(30)
    end

    -- 1 + 2 + 3
    local a_line, a_id = line_of('src/a.ts', 'unstaged')
    Actions.toggle_stage(state, a_id)
    wait(200) -- 越过 150ms 延迟
    local marks = loading_marks()
    assert(#marks == 1 and marks[1].row == a_line and marks[1].col == a_id.icon_col and marks[1].pos == 'overlay',
      '写入在途时帧应盖在 a.ts 的图标槽: ' .. vim.inspect(marks) .. ' icon_col=' .. tostring(a_id.icon_col))

    table.remove(writes).cb(true, nil, true)
    wait(30)
    assert(#reloads == 1, '写入完成应触发 reload')
    assert(#loading_marks() == 1, '写入完成、reload 未渲染前帧必须保留（文件仍在 Changes）')

    status[ROOT .. '/src/a.ts'] = 'M '
    finish_reload(vim.deepcopy(status))
    assert(line_of('src/a.ts', 'staged'), '前置：reload 后 a.ts 应移到 Staged')
    wait(30)
    assert(#loading_marks() == 0, '写入后发起的 reload 渲染完成，帧必须消失: ' .. vim.inspect(loading_marks()))

  end)
end

T['写入之前发起的旧刷新不得清除暂存加载帧'] = function()
  child.lua_func(function()
    -- stage / unstage 在途 loading：
    --   1. 帧盖在被操作文件的图标槽（overlay），不在行尾
    --   2. Git 写入完成后、reload 渲染前帧保留（文件仍在旧分组，此时停掉看起来像没生效）
    --   3. 写入完成后发起的 reload 渲染完成，帧消失
    --   4. 写入完成「之前」就发起的 reload 结束时不得清掉帧（它的结果不含这次写入）
    --   5. 写入失败帧立即消失

    local State = require('vv-git.state')
    local Tree = require('vv-git.tree')
    local Render = require('vv-git.left.render')
    local Panel = require('vv-git.left.panel')
    local Git = require('vv-git.git')
    local Loader = require('vv-git.loader')
    local Actions = require('vv-git.left.actions')

    local ROOT = '/tmp/vv-git-stage-loading-fake'
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

    local status = {
      [ROOT .. '/src/a.ts'] = ' M',
      [ROOT .. '/src/b.ts'] = ' M',
      [ROOT .. '/src/c.ts'] = ' M',
    }
    state.tree = Tree.build(status, ROOT)
    Render.render(state)

    -- Git 写入与 reload 全部挂起，由测试决定完成时机
    local writes, reloads = {}, {}
    Git.stage = function(_, paths, cb) writes[#writes + 1] = { paths = paths, cb = cb } end
    Git.unstage = Git.stage
    Git.index = function(_, cb)
      reloads[#reloads + 1] = cb
      return function() end
    end
    Git.repo_info = function(_, cb) cb(INFO); return function() end end
    local notify = vim.notify
    vim.notify = function() end

    local function line_of(relpath, base)
      for lnum, id in pairs(state.panel.id_by_line) do
        if id.node and id.node.relpath == relpath and id.base == base then return lnum, id end
      end
    end

    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local chunk = mark[4].virt_text and mark[4].virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then
          result[#result + 1] = { row = mark[2] + 1, col = mark[3], pos = mark[4].virt_text_pos }
        end
      end
      return result
    end

    local function wait(ms) vim.wait(ms, function() return false end, 10) end

    --- 完成最近一次 reload，用给定状态重建树
    local function finish_reload(map)
      local cb = table.remove(reloads)
      assert(cb, '应有一个在途 reload')
      cb({ status_map = map, rename_map = {} })
      wait(30)
    end

    -- 4：写入完成前发起、写入完成后才结束的 reload 不得清帧（它的结果不含这次写入）
    --    快速连按时写入回调 idle=false 不触发新 reload，旧 reload 才可能在写入之后完成
    local _, b_id = line_of('src/b.ts', 'unstaged')
    Actions.toggle_stage(state, b_id)
    wait(200)
    Loader.reload_index(state) -- 例如自动刷新，在写入完成前发起
    table.remove(writes).cb(true, nil, false) -- 写入完成，但队列未空不触发 reload
    wait(30)
    finish_reload(vim.deepcopy(status)) -- 旧 reload 此刻才结束，结果仍是写入前的状态
    assert(#loading_marks() == 1, '写入完成前发起的 reload 结束时帧必须保留')

    status[ROOT .. '/src/b.ts'] = 'M '
    Loader.reload_index(state) -- 队列最后一项触发的 reload
    finish_reload(vim.deepcopy(status))
    assert(#loading_marks() == 0, '写入后发起的 reload 完成后帧必须消失')

  end)
end

T['暂存失败立即释放加载帧而不等待刷新'] = function()
  child.lua_func(function()
    -- stage / unstage 在途 loading：
    --   1. 帧盖在被操作文件的图标槽（overlay），不在行尾
    --   2. Git 写入完成后、reload 渲染前帧保留（文件仍在旧分组，此时停掉看起来像没生效）
    --   3. 写入完成后发起的 reload 渲染完成，帧消失
    --   4. 写入完成「之前」就发起的 reload 结束时不得清掉帧（它的结果不含这次写入）
    --   5. 写入失败帧立即消失

    local State = require('vv-git.state')
    local Tree = require('vv-git.tree')
    local Render = require('vv-git.left.render')
    local Panel = require('vv-git.left.panel')
    local Git = require('vv-git.git')
    local Loader = require('vv-git.loader')
    local Actions = require('vv-git.left.actions')

    local ROOT = '/tmp/vv-git-stage-loading-fake'
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

    local status = {
      [ROOT .. '/src/a.ts'] = ' M',
      [ROOT .. '/src/b.ts'] = ' M',
      [ROOT .. '/src/c.ts'] = ' M',
    }
    state.tree = Tree.build(status, ROOT)
    Render.render(state)

    -- Git 写入与 reload 全部挂起，由测试决定完成时机
    local writes, reloads = {}, {}
    Git.stage = function(_, paths, cb) writes[#writes + 1] = { paths = paths, cb = cb } end
    Git.unstage = Git.stage
    Git.index = function(_, cb)
      reloads[#reloads + 1] = cb
      return function() end
    end
    Git.repo_info = function(_, cb) cb(INFO); return function() end end
    local notify = vim.notify
    vim.notify = function() end

    local function line_of(relpath, base)
      for lnum, id in pairs(state.panel.id_by_line) do
        if id.node and id.node.relpath == relpath and id.base == base then return lnum, id end
      end
    end

    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local chunk = mark[4].virt_text and mark[4].virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then
          result[#result + 1] = { row = mark[2] + 1, col = mark[3], pos = mark[4].virt_text_pos }
        end
      end
      return result
    end

    local function wait(ms) vim.wait(ms, function() return false end, 10) end

    --- 完成最近一次 reload，用给定状态重建树
    local function finish_reload(map)
      local cb = table.remove(reloads)
      assert(cb, '应有一个在途 reload')
      cb({ status_map = map, rename_map = {} })
      wait(30)
    end

    -- 5：失败立即消失
    local _, c_id = line_of('src/c.ts', 'unstaged')
    Actions.toggle_stage(state, c_id)
    wait(200)
    assert(#loading_marks() == 1, '前置：c.ts 帧已显示')
    table.remove(writes).cb(false, 'boom', true)
    wait(30)
    assert(#loading_marks() == 0, '写入失败帧必须立即消失，不等 reload')

  end)
end

return T
