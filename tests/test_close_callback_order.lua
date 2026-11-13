-- 关闭回调顺序：先恢复 before_open 挂起的界面，再通知 on_close
-- on_close 常用来重开 picker 等浮窗；恢复界面排在其后会切换窗口，使浮窗失焦关闭
local T, child = dofile('tests/helpers.lua').new_set()

T['关闭后先执行 before_open 的恢复函数，再执行 on_close'] = function()
  child.lua_func(function()
    local Plugin = require('vv-git')
    local order = {}
    Plugin.setup({
      before_open = function()
        return function() order[#order + 1] = 'resume' end
      end,
      keymap_toggle_panel = false,
      auto_refresh = false,
      preview = false,
      subrepo = { depth = 0 },
    })

    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
    vim.fn.system({ 'git', '-C', tmpdir, 'init', '-q' })
    vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.name', 'vv-git test' })
    vim.fn.system({ 'git', '-C', tmpdir, 'config', 'user.email', 'test@example.com' })
    vim.fn.writefile({ 'committed' }, tmpdir .. '/sample.txt')
    vim.fn.system({ 'git', '-C', tmpdir, 'add', 'sample.txt' })
    vim.fn.system({ 'git', '-C', tmpdir, 'commit', '-qm', 'initial' })

    local ready = false
    local opened = Plugin.open({
      root = tmpdir,
      on_ready = function() ready = true end,
      on_close = function() order[#order + 1] = 'on_close' end,
    })
    assert(opened, 'open 应成功')
    assert(vim.wait(3000, function() return ready end), 'open 应调用就绪回调')

    Plugin.close()
    assert(vim.wait(1000, function() return #order == 2 end), '恢复函数与 on_close 都应执行')
    assert(order[1] == 'resume' and order[2] == 'on_close', '恢复函数必须先于 on_close')
  end)
end

return T
