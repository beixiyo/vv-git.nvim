-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['复制路径默认静默，显式提示与非法配置拒绝'] = function()
  child.lua_func(function()
    -- Y 复制路径的提示契约：默认成功静默，yank_notify = true 恢复成功提示，非法配置在 setup 边界报错


    -- 假剪贴板 provider：走真实 setreg('+') 链路，同时记录写入内容
    local clipboard = {}
    vim.g.clipboard = {
      name = 'test',
      copy = {
        ['+'] = function(lines) clipboard[#clipboard + 1] = table.concat(lines, '\n') end,
        ['*'] = function() end,
      },
      paste = {
        ['+'] = function() return {} end,
        ['*'] = function() return {} end,
      },
    }

    local notified = {}
    vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end

    local Plugin = require('vv-git')
    local State = require('vv-git.state')
    -- 与 init.lua 的组合方式一致：命令模块从 config() 读取 setup 归一化后的配置
    local Commands = require('vv-git.core.commands.file').new({ controller = {}, config = Plugin.get_config })

    local base_opts = { keymap_toggle_panel = false, auto_refresh = false, preview = false }

    -- 光标在 diff 窗口时 Y 复制当前 view 文件的绝对路径（不依赖面板树）
    local function yank(opts)
      Plugin.setup(vim.tbl_extend('force', base_opts, opts or {}))
      State.clear()
      local state = State.create()
      state.git_root = '/tmp/project'
      local win = vim.api.nvim_get_current_win()
      state.view = { path = 'src/a.lua', a_win = win, b_win = win }

      clipboard, notified = {}, {}
      Commands._yank_abs_path()
    end

    yank()
    assert(clipboard[1] == '/tmp/project/src/a.lua', '路径未写入剪贴板：' .. vim.inspect(clipboard))
    assert(#notified == 0, 'default yank should be silent, 实际 ' .. vim.inspect(notified))

    yank({ yank_notify = true })
    assert(clipboard[1] == '/tmp/project/src/a.lua', '路径未写入剪贴板')
    assert(#notified == 1 and notified[1].msg == 'Copied: /tmp/project/src/a.lua',
      'yank_notify should report success, 实际 ' .. vim.inspect(notified))

    local ok, err = pcall(Plugin.setup, vim.tbl_extend('force', base_opts, { yank_notify = 'all' }))
    assert(not ok and tostring(err):find('yank_notify must be a boolean', 1, true),
      'invalid yank_notify should be rejected, 实际 ' .. tostring(err))

    State.clear()
  end)
end

return T
