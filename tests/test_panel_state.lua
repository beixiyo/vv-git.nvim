-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['无效宽度回退，缩放和关闭持久化最后宽度'] = function()
  child.lua_func(function()
    -- vv-git 面板宽度状态集成


    local values = { width = 'invalid' }
    local handle = {
      get = function(_, field, default)
        local value = values[field]
        return value == nil and default or value
      end,
      set = function(_, field, value)
        values[field] = value
        return true
      end,
    }

    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    vim.fn.system({ 'git', '-C', tmp, 'init', '--quiet' })

    local git = require('vv-git')
    git.setup({
      state = handle,
      width = 31,
      auto_refresh = false,
      preview = false,
      keymap_toggle_panel = false,
    })

    assert(git.open({ root = tmp }), 'vv-git 应在临时仓库打开')
    assert(vim.api.nvim_win_get_width(0) == 31, '无效的持久化宽度应回退到配置值')

    vim.cmd('vertical resize 43')
    vim.api.nvim_exec_autocmds('WinResized', {})
    vim.wait(250, function() return values.width == 43 end)
    assert(values.width == 43, ':vertical resize 应在防抖后持久化')

    vim.cmd('tabclose')
    vim.wait(100, function() return not git.is_open() end)
    assert(values.width == 43, '直接 :tabclose 应刷新最近一次面板宽度')

    vim.fn.delete(tmp, 'rf')
  end)
end

return T
