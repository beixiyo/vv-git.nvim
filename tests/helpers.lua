-- 每个具名用例拥有独立子进程与隔离临时根目录；失败也由父进程兜底清理
local M = {}
local Processes = dofile(assert(vim.env.VV_UTILS) .. '/dev/test/process.lua')

function M.new_set()
  local MiniTest = require('mini.test')
  local child = MiniTest.new_child_neovim()
  local root, pid
  local T = MiniTest.new_set({
    hooks = {
      pre_case = function()
        pid = nil
        assert(type(vim.env.VV_TEST_REPO) == 'string' and vim.env.VV_TEST_REPO ~= '', '被测仓库路径不能为空')
        assert(type(vim.env.VV_UTILS) == 'string' and vim.env.VV_UTILS ~= '', '共享工具路径不能为空')
        local icons = vim.env.VV_ICONS
        if icons then
          assert(icons ~= '', '图标依赖路径不能为空')
          assert(vim.fn.isdirectory(icons) == 1, '图标依赖路径必须存在')
        end
        root = assert(vim.uv.fs_mkdtemp(assert(vim.env.TMPDIR) .. '/cXXXXXX'))
        -- 所有场景使用规范路径，避免 /var 与 /private/var 别名破坏真实路径契约
        root = assert(vim.uv.fs_realpath(root))
        local environment = {
          HOME = root .. '/home', TMPDIR = root .. '/tmp', VV_TEST_TMP = root,
          XDG_CONFIG_HOME = root .. '/config', XDG_DATA_HOME = root .. '/data',
          XDG_STATE_HOME = root .. '/state', XDG_CACHE_HOME = root .. '/cache',
        }
        local previous = {}
        for key, value in pairs(environment) do
          assert(type(value) == 'string' and value ~= '', '隔离环境路径不能为空：' .. key)
          vim.fn.mkdir(value, 'p')
          previous[key], vim.env[key] = vim.env[key], value
        end
        -- 启动前注入环境与 cwd；父进程在连接成功或失败时都恢复原环境
        local tempname = vim.fn.tempname
        vim.fn.tempname = function()
          return root .. '/child.sock'
        end
        local started, start_err = pcall(child.start, {
          '-u', 'NONE', '-i', 'NONE', '-n', '--cmd', 'cd ' .. vim.fn.fnameescape(root),
        }, { nvim_executable = vim.v.progpath })
        vim.fn.tempname = tempname
        for key in pairs(environment) do
          vim.env[key] = previous[key]
        end
        if child.job then
          pid = vim.fn.jobpid(child.job.id)
        end
        assert(started, '启动隔离子进程失败：' .. tostring(start_err))
        if icons then
          child.env.VV_ICONS = icons
        end
        child.lua([[
        local root = assert(vim.env.VV_TEST_TMP, '临时根目录不能为空')
        assert(root ~= '' and vim.fn.isdirectory(root) == 1, '临时根目录必须存在')
        assert(vim.uv.fs_realpath(vim.fn.getcwd()) == vim.uv.fs_realpath(root), '子进程 cwd 必须在本场景 fixture')
        for _, key in ipairs({ 'HOME', 'TMPDIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME' }) do
          local path = vim.env[key]
          assert(type(path) == 'string' and path:sub(1, #root + 1) == root .. '/', '环境路径未隔离：' .. key)
        end
        for _, kind in ipairs({ 'config', 'data', 'state', 'cache' }) do
          assert(vim.fn.stdpath(kind):sub(1, #root + 1) == root .. '/', '持久目录未隔离：' .. kind)
        end
        assert(type(vim.env.VV_TEST_REPO) == 'string' and vim.env.VV_TEST_REPO ~= '', '被测仓库路径不能为空')
        assert(type(vim.env.VV_UTILS) == 'string' and vim.env.VV_UTILS ~= '', '共享工具路径不能为空')
        assert(vim.fn.isdirectory(vim.env.VV_TEST_REPO) == 1, '被测仓库路径必须存在')
        assert(vim.fn.isdirectory(vim.env.VV_UTILS) == 1, '共享工具路径必须存在')
        vim.opt.packpath = ''
        dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
        vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
        vim.opt.runtimepath:prepend(vim.env.VV_UTILS)
        if vim.env.VV_ICONS then
          assert(vim.env.VV_ICONS ~= '' and vim.fn.isdirectory(vim.env.VV_ICONS) == 1, '图标依赖路径必须非空且存在')
          vim.opt.runtimepath:prepend(vim.env.VV_ICONS)
        end
        vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_SYSTEM = '/dev/null', '/dev/null'
        vim.env.GIT_INDEX_FILE, vim.env.GIT_DIR, vim.env.GIT_WORK_TREE = nil, nil, nil
        vim.env.GIT_CONFIG_COUNT = nil
        local counter = 0
        vim.fn.tempname = function()
          counter = counter + 1
          return vim.env.VV_TEST_TMP .. '/fixture-' .. counter
        end
        async_errors, allowed_errors = {}, {}
        local schedule = vim.schedule
        vim.schedule = function(callback)
          schedule(function()
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then async_errors[#async_errors + 1] = tostring(err) end
          end)
        end
        vim.v.errmsg = ''
      ]])
      end,
      post_case = function()
        -- 取证失败不能绕过进程停止与目录删除；不调用可能已被测试替换的生产接口
        local ok, err = pcall(function()
          local errors = child.lua_get([[(function()
          local errors = vim.deepcopy(async_errors)
          if vim.v.errmsg ~= '' then errors[#errors + 1] = vim.v.errmsg end
          local unexpected = {}
          for _, message in ipairs(errors) do
            local allowed = false
            for _, expected in ipairs(allowed_errors) do
              if message:gsub('[\r\n]+$', '') == expected then allowed = true end
            end
            if not allowed then unexpected[#unexpected + 1] = message end
          end
          return unexpected
        end)()]])
          assert(#errors == 0, '子进程出现未预期的异步错误：' .. vim.inspect(errors))
        end)
        local descendants_ok, descendants_err = pcall(Processes.stop_descendants, pid)
        local stopped, stop_err = pcall(child.stop)
        pid = nil
        local cleaned = not root or vim.fn.delete(root, 'rf') == 0
        root = nil
        assert(cleaned, '清理场景 fixture 失败')
        assert(stopped, '停止子进程失败：' .. tostring(stop_err))
        assert(descendants_ok, '清理子进程后代失败：' .. tostring(descendants_err))
        assert(ok, err)
      end,
    },
  })
  return T, child
end

-- 选项来源契约经真正输入队列执行，避免 RPC 把所有 API 写入标成相同 channel
-- 函数必须自包含；异步结果与命令错误仍传回父进程断言
function M.run_user(child, action, ...)
  child.lua_func(function(code, args)
    TestAction = assert(loadstring(code))
    user_args, user_result = args, nil
  end, string.dump(action), { ... })
  child.type_keys(':lua local ok, err = xpcall(function() return TestAction(unpack(user_args)) end, debug.traceback); user_result = { ok, err }<CR>')
  local result
  assert(vim.wait(30000, function()
    result = child.lua_get('user_result')
    return type(result) == 'table'
  end, 10), '真实用户命令尚未完成')
  assert(result[1], result[2])
end

return M
