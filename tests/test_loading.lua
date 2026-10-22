-- 刷新、推送与提交的独立加载生命周期，不共享替换过的进程接口。
local T, child = dofile('tests/helpers.lua').new_set()

T['被替代刷新不清除最新请求的加载帧'] = function()
  child.lua_func(function()
    -- 左栏 loading 生命周期：手动刷新被顶替不隐藏新请求的显示、push 在途忽略重复按键并在终结时停止

    local State = require('vv-git.state')
    local Tree = require('vv-git.tree')
    local Render = require('vv-git.left.render')
    local Panel = require('vv-git.left.panel')
    local Git = require('vv-git.git')

    local ROOT = '/tmp/vv-git-loading-fake'

    local buf = Panel.create_buf()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    State.clear()
    local state = State.create()
    state.git_root = ROOT
    state.panel = { buf = buf, win = win, main_win = win }
    state.folds, state.section_folds, state.selection, state.block_folds = {}, {}, {}, {}
    state.tree = Tree.build({}, ROOT)
    state.repo_info = { upstream = 'origin/main', ahead = 2, behind = 0, branch = 'main', branch_name = 'main', head = 'abc', remotes = { 'origin' } }
    state.branch = 'main'
    Render.render(state)

    ---@param match fun(id: table): boolean
    ---@return integer? lnum
    local function line_of(match)
      for lnum, id in pairs(state.panel.id_by_line) do
        if match(id) then return lnum end
      end
    end

    ---@return { row: integer, col: integer, text: string, pos: string }[]
    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local details = mark[4]
        local chunk = details.virt_text and details.virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then
          result[#result + 1] = { row = mark[2] + 1, col = mark[3], text = chunk[1], pos = details.virt_text_pos }
        end
      end
      return result
    end

    local header = line_of(function(id) return id.block_header == ROOT end)
    assert(header, '根仓库标题行应带 block_header id')

    -- ── V4：手动刷新 ────────────────────────────────────────────────────────────
    -- Git 回调全部挂起，由测试决定每个 reload 何时完成
    local pending = {}
    local original_index, original_repo_info, original_push = Git.index, Git.repo_info, Git.push
    Git.index = function(_, cb)
      pending[#pending + 1] = { kind = 'index', cb = cb }
      return function() end
    end
    Git.repo_info = function(_, cb)
      pending[#pending + 1] = { kind = 'info', cb = cb }
      return function() end
    end

    local Lifecycle = require('vv-git.core.lifecycle').new({
      controller = {},
      config = function() return {} end,
      track_panel_width = function() end,
      persist_panel_width = function() end,
      initial_panel_width = function() return 30 end,
    })

    Lifecycle._manual_refresh()
    local first = pending
    pending = {}
    Lifecycle._manual_refresh()
    local second = pending
    pending = {}

    -- 第一个 reload 已被顶替（cancel_previous）；它的 release 不能停掉第二个 reload 的显示
    local marks = loading_marks()
    assert(#marks == 1 and marks[1].row == header and marks[1].col == 0 and marks[1].pos == 'overlay',
      '被顶替的刷新终结后，新刷新的 loading 应仍盖在根仓库标题行箭头上: ' .. vim.inspect(marks))

    -- 过期请求的迟到回调既不渲染也不影响显示
    for _, p in ipairs(first) do p.cb(p.kind == 'index' and { status_map = {}, rename_map = {} } or state.repo_info) end
    assert(#loading_marks() == 1, '过期 reload 的迟到回调不应停止当前 loading')

    -- 当前请求完成（结果无变化，走 skip_render 分支也必须终结请求）
    for _, p in ipairs(second) do p.cb(p.kind == 'index' and { status_map = {}, rename_map = {} } or state.repo_info) end
    assert(#loading_marks() == 0, '最后一个刷新完成后 loading 应清除: ' .. vim.inspect(loading_marks()))

    Git.index, Git.repo_info = original_index, original_repo_info

  end)
end

T['推送在途去重且失败成功都释放提示行加载帧'] = function()
  child.lua_func(function()
    -- 左栏 loading 生命周期：手动刷新被顶替不隐藏新请求的显示、push 在途忽略重复按键并在终结时停止

    local State = require('vv-git.state')
    local Tree = require('vv-git.tree')
    local Render = require('vv-git.left.render')
    local Panel = require('vv-git.left.panel')
    local Git = require('vv-git.git')

    local ROOT = '/tmp/vv-git-loading-fake'

    local buf = Panel.create_buf()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    State.clear()
    local state = State.create()
    state.git_root = ROOT
    state.panel = { buf = buf, win = win, main_win = win }
    state.folds, state.section_folds, state.selection, state.block_folds = {}, {}, {}, {}
    state.tree = Tree.build({}, ROOT)
    state.repo_info = { upstream = 'origin/main', ahead = 2, behind = 0, branch = 'main', branch_name = 'main', head = 'abc', remotes = { 'origin' } }
    state.branch = 'main'
    Render.render(state)

    ---@param match fun(id: table): boolean
    ---@return integer? lnum
    local function line_of(match)
      for lnum, id in pairs(state.panel.id_by_line) do
        if match(id) then return lnum end
      end
    end

    ---@return { row: integer, col: integer, text: string, pos: string }[]
    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local details = mark[4]
        local chunk = details.virt_text and details.virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then
          result[#result + 1] = { row = mark[2] + 1, col = mark[3], text = chunk[1], pos = details.virt_text_pos }
        end
      end
      return result
    end

    local header = line_of(function(id) return id.block_header == ROOT end)
    assert(header, '根仓库标题行应带 block_header id')

    local original_push = Git.push
    local marks
    -- ── V1：push 在途 ──────────────────────────────────────────────────────────
    local push_calls = {}
    Git.push = function(root, cb)
      push_calls[#push_calls + 1] = { root = root, cb = cb }
      return function() push_calls[#push_calls].cancelled = true end
    end
    local original_notify = vim.notify
    vim.notify = function() end

    local refreshed = 0
    local commands = require('vv-git.core.commands').new({
      controller = { refresh = function() refreshed = refreshed + 1 end },
      config = function() return {} end,
    })

    local hint = line_of(function(id) return id.action == 'push' end)
    assert(hint, 'Push 提示行应带 action = push')
    vim.api.nvim_win_set_cursor(win, { hint, 0 })

    commands._push()
    commands._push()
    assert(#push_calls == 1, '在途 push 期间重复按 p 应被忽略，不得派生/取消进程')
    assert(not push_calls[1].cancelled, '重复按键不得取消在途 push')

    marks = loading_marks()
    local hint_line = vim.api.nvim_buf_get_lines(buf, hint - 1, hint, false)[1]
    local expected_col = #hint_line:match('^%s*p%s%s')
    assert(#marks == 1 and marks[1].row == hint and marks[1].col == expected_col and marks[1].pos == 'inline',
      'push loading 应插在提示文字开头: ' .. vim.inspect({ marks = marks, line = hint_line }))

    push_calls[1].cb(false, 'rejected')
    assert(#loading_marks() == 0, 'push 失败终结后 loading 应停止')

    commands._push()
    assert(#push_calls == 2, 'push 终结后可再次发起')
    push_calls[2].cb(true, nil)
    assert(#loading_marks() == 0 and refreshed == 1, 'push 成功终结后 loading 停止并刷新')

    -- 没有提示行（ahead=0 也按 p）：退到仓库标题行箭头槽
    state.repo_info = vim.tbl_extend('force', state.repo_info, { ahead = 0 })
    Render.render(state)
    vim.api.nvim_win_set_cursor(win, { header, 0 })
    commands._push()
    marks = loading_marks()
    assert(#marks == 1 and marks[1].row == header and marks[1].col == 0 and marks[1].pos == 'overlay',
      '无提示行时 push loading 应盖在仓库标题行箭头上: ' .. vim.inspect(marks))
    push_calls[3].cb(true, nil)

  end)
end

T['提交在途页脚与只读状态在失败后恢复'] = function()
  child.lua_func(function()
    -- 左栏 loading 生命周期：手动刷新被顶替不隐藏新请求的显示、push 在途忽略重复按键并在终结时停止

    local State = require('vv-git.state')
    local Tree = require('vv-git.tree')
    local Render = require('vv-git.left.render')
    local Panel = require('vv-git.left.panel')
    local Git = require('vv-git.git')

    local ROOT = '/tmp/vv-git-loading-fake'

    local buf = Panel.create_buf()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    State.clear()
    local state = State.create()
    state.git_root = ROOT
    state.panel = { buf = buf, win = win, main_win = win }
    state.folds, state.section_folds, state.selection, state.block_folds = {}, {}, {}, {}
    state.tree = Tree.build({}, ROOT)
    state.repo_info = { upstream = 'origin/main', ahead = 2, behind = 0, branch = 'main', branch_name = 'main', head = 'abc', remotes = { 'origin' } }
    state.branch = 'main'
    Render.render(state)

    ---@param match fun(id: table): boolean
    ---@return integer? lnum
    local function line_of(match)
      for lnum, id in pairs(state.panel.id_by_line) do
        if match(id) then return lnum end
      end
    end

    ---@return { row: integer, col: integer, text: string, pos: string }[]
    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local details = mark[4]
        local chunk = details.virt_text and details.virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then
          result[#result + 1] = { row = mark[2] + 1, col = mark[3], text = chunk[1], pos = details.virt_text_pos }
        end
      end
      return result
    end

    local header = line_of(function(id) return id.block_header == ROOT end)
    assert(header, '根仓库标题行应带 block_header id')

    vim.notify = function() end
    -- ── V3：commit 浮窗 footer ─────────────────────────────────────────────────
    local commit_cb
    local original_commit = Git.commit
    Git.commit = function(_, _, cb) commit_cb = cb end
    local Prompt = require('vv-git.left.prompt')
    Prompt.open({ git_root = ROOT, has_staged = true })
    local prompt_win = vim.api.nvim_get_current_win()
    local prompt_buf = vim.api.nvim_get_current_buf()
    local function footer_text()
      local footer = vim.api.nvim_win_get_config(prompt_win).footer
      if type(footer) == 'string' then return footer end
      local parts = {}
      for _, chunk in ipairs(footer or {}) do parts[#parts + 1] = chunk[1] end
      return table.concat(parts)
    end
    local original_footer = footer_text()
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { 'feat: message' })
    vim.fn.maparg('<C-s>', 'n', false, true).callback()
    assert(commit_cb, '<C-s> 应发起 commit')
    assert(footer_text():find('Committing', 1, true) and not vim.bo[prompt_buf].modifiable,
      '提交在途时 footer 显示 loading 且 message 只读: ' .. footer_text())
    commit_cb(false, 'hook failed')
    assert(footer_text() == original_footer and vim.bo[prompt_buf].modifiable,
      'commit 失败后应恢复原 footer 与可编辑状态: ' .. footer_text())
    Prompt.close()
    Git.commit = original_commit

  end)
end

return T
