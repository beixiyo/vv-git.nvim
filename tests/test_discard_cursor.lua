-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['真实确认框刷新与取消保持光标，确认后推进邻居'] = function()
  child.lua_func(function()
    -- 回归：工作区文件按 `d` 弹出确认框期间，左栏光标不得被拉走
    -- 真实确认框会进入浮窗 → BufEnter 触发 auto_refresh → passive reload；按键时预设的
    -- _action_hint 若在此时被消费，光标会在用户确认前就跳到相邻文件
    --   1. 确认框打开、auto_refresh 完成后光标仍在原文件
    --   2. 取消后仍在原文件
    --   3. 确认并 reload 后落到原 section 的下一个文件


    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, 'p')

    local function git(args)
      local command = { 'git', '-C', repo }
      vim.list_extend(command, args)
      local result = vim.system(command, { text = true }):wait()
      assert(result.code == 0, result.stderr)
      return result.stdout
    end

    git({ 'init', '-q' })
    git({ 'config', 'user.name', 'vv-git test' })
    git({ 'config', 'user.email', 'test@example.com' })
    for _, name in ipairs({ 'a', 'b', 'c' }) do vim.fn.writefile({ name .. '1' }, repo .. '/' .. name .. '.txt') end
    git({ 'add', '.' })
    git({ 'commit', '-qm', 'initial' })
    for _, name in ipairs({ 'a', 'b', 'c' }) do vim.fn.writefile({ name .. '2' }, repo .. '/' .. name .. '.txt') end

    local Plugin = require('vv-git')
    local State = require('vv-git.state')
    local Git = require('vv-git.git')

    Plugin.setup({
      preview = false,
      keymap_toggle_panel = false,
      subrepo = { depth = 0 },
    })

    local ready, open_error
    assert(Plugin.open({
      root = repo,
      on_ready = function() ready = true end,
      on_error = function(err) open_error = err end,
    }))
    assert(vim.wait(3000, function() return ready end), open_error or '仓库未打开')

    local state = State.get()
    local panel = state.panel

    local function line_of(relpath)
      for lnum, id in pairs(panel.id_by_line) do
        if id.node and id.node.relpath == relpath and id.base == 'unstaged' then return lnum end
      end
    end

    local function cursor_path()
      local id = panel.id_by_line[vim.api.nvim_win_get_cursor(panel.win)[1]]
      return id and id.node and id.node.relpath
    end

    local function mapping(buf, lhs)
      for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if item.lhs == lhs then return item.callback end
      end
    end

    local index_calls = 0
    local original_index = Git.index
    Git.index = function(...)
      index_calls = index_calls + 1
      return original_index(...)
    end

    local function press_discard_on(relpath)
      vim.api.nvim_set_current_win(panel.win)
      vim.api.nvim_win_set_cursor(panel.win, { assert(line_of(relpath), relpath .. ' 不在面板'), 0 })
      assert(mapping(panel.buf, 'd'), '面板未设置 d 映射')()
      assert(vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vv-confirm', '应进入确认浮窗')
    end

    -- 等确认框引起的 BufEnter auto_refresh（200ms 防抖）跑完一轮 reload
    local function wait_refresh()
      local before = index_calls
      assert(vim.wait(3000, function() return index_calls > before end), '确认框打开后应触发 auto_refresh')
      vim.wait(300, function() return false end, 10)
    end

    -- 1 + 2：确认框打开期间与取消后
    press_discard_on('b.txt')
    wait_refresh()
    assert(cursor_path() == 'b.txt', '确认框打开期间光标被拉到 ' .. tostring(cursor_path()))

    vim.api.nvim_feedkeys('q', 'x', false)
    assert(vim.api.nvim_get_current_win() == panel.win, '取消后焦点应回到面板')
    vim.wait(500, function() return false end, 10)
    assert(cursor_path() == 'b.txt', '取消后光标被拉到 ' .. tostring(cursor_path()))
    assert(git({ 'status', '--short' }):find(' M b.txt', 1, true), '取消不得丢弃')

    -- 3：确认后落到下一个文件
    press_discard_on('b.txt')
    wait_refresh()
    vim.api.nvim_feedkeys(vim.keycode('<C-y>'), 'x', false)
    assert(vim.wait(3000, function() return state.tree and not line_of('b.txt') end), 'b.txt 应被丢弃')
    vim.wait(300, function() return false end, 10)
    assert(cursor_path() == 'c.txt', '确认后应落到下一个文件 c.txt，实际为 ' .. tostring(cursor_path()))

    Git.index = original_index
    Plugin.close()
    vim.fn.delete(repo, 'rf')
  end)
end

return T
