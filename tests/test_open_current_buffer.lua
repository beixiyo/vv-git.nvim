-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['隐式打开的初始差异跟随触发文件'] = function()
  child.lua_func(function()
    -- 回归：无参数打开 vv-git 时，初始 diff 必须跟随触发打开的当前 buffer


    local Plugin = require('vv-git')
    local State = require('vv-git.state')

    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, 'p')

    local function git(args)
      local command = { 'git', '-C', repo }
      vim.list_extend(command, args)
      local result = vim.system(command, { text = true }):wait()
      assert(result.code == 0, result.stderr)
    end

    git({ 'init', '-q' })
    git({ 'config', 'user.name', 'vv-git test' })
    git({ 'config', 'user.email', 'test@example.com' })
    vim.fn.writefile({ 'initial a' }, repo .. '/a.txt')
    vim.fn.writefile({ 'initial z' }, repo .. '/z.txt')
    git({ 'add', 'a.txt', 'z.txt' })
    git({ 'commit', '-qm', 'initial' })
    vim.fn.writefile({ 'changed a' }, repo .. '/a.txt')
    vim.fn.writefile({ 'changed z' }, repo .. '/z.txt')

    local original_cwd = vim.fn.getcwd()
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/z.txt'))

    Plugin.setup({
      auto_refresh = false,
      preview = true,
      preview_debounce_ms = 0,
      keymap_toggle_panel = false,
      subrepo = { depth = 0 },
    })

    assert(Plugin.toggle(), 'VVGitToggle 应打开当前仓库')
    assert(vim.wait(3000, function() return State.get().tree ~= nil end), '仓库索引未加载')
    -- 真实 UI 中 render 移动左栏光标后会触发该事件；headless 中显式重放
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = State.get().panel.buf })
    assert(vim.wait(3000, function()
      local state = State.get()
      return state.view ~= nil
    end), '初始 diff 未显示')

    local state = State.get()
    assert(state.cur_path == 'z.txt', '当前文件应为触发打开的 z.txt，实际为 ' .. tostring(state.cur_path))
    assert(state.view.path == 'z.txt', '初始 diff 应显示 z.txt，实际为 ' .. tostring(state.view.path))

    Plugin.close()
    assert(vim.wait(1000, function() return not Plugin.is_open() end), '测试面板未关闭')
    vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))
    vim.fn.delete(repo, 'rf')
  end)
end

return T
