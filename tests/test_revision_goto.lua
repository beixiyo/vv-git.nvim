-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['修订视图透传调用方跳转策略并保留面板'] = function()
  child.lua_func(function()
    -- show_commit 必须把调用方的 gf 策略传到真实 revision session，避免关闭 vv-git 后误触发上层恢复


    local Plugin = require('vv-git')
    local State = require('vv-git.state')
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
    vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
    vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
    vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
    vim.fn.writefile({ 'committed' }, tmpdir .. '/sample.txt')
    vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
    vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })

    Plugin.setup({ keymap_toggle_panel = false, auto_refresh = false, preview = false })

    local goto_context
    local close_count = 0
    assert(Plugin.show_commit('HEAD', {
      root = tmpdir,
      on_close = function() close_count = close_count + 1 end,
      on_goto_file = function(context) goto_context = context end,
    }), 'show_commit 应启动 revision 面板')

    assert(vim.wait(3000, function()
      local state = State.current()
      return state and state.compare ~= nil and type(state._on_goto_file) == 'function'
    end), 'show_commit 应将 gf 策略传入 revision state')

    local state = assert(State.current())
    vim.api.nvim_set_current_win(state.panel.win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)

    assert(vim.wait(1000, function()
      return state.view and state.view.b_win and vim.api.nvim_win_is_valid(state.view.b_win)
    end), 'revision 应创建可跳转的 diff 窗口')

    vim.api.nvim_set_current_win(state.view.b_win)
    vim.api.nvim_win_set_cursor(state.view.b_win, { 1, 3 })
    local goto_map
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(state.view.b_win), 'n')) do
      if mapping.lhs == 'gf' then goto_map = mapping; break end
    end
    assert(goto_map and type(goto_map.callback) == 'function', 'revision diff 窗口应安装 gf 回调')
    goto_map.callback()

    assert(vim.wait(1000, function() return goto_context ~= nil end), 'gf 应调用自定义跳转策略')
    assert(goto_context.root == vim.uv.fs_realpath(tmpdir), 'gf context 应包含仓库 root')
    assert(goto_context.path == 'sample.txt', 'gf context 应包含相对路径')
    assert(goto_context.row == 1, 'gf context 应包含当前 diff 行')
    assert(goto_context.col == 3, 'gf context 应包含当前 diff 列')
    assert(Plugin.is_open(), '自定义 gf 策略应保留 vv-git tab')
    assert(close_count == 0, '自定义 gf 策略不应触发 close 回调')

    Plugin.close()
    vim.fn.delete(tmpdir, 'rf')
  end)
end

return T
