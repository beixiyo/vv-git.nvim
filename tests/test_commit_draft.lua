-- 验证提交草稿的磁盘恢复、仓库隔离与提交结果边界
local T, child = dofile('tests/helpers.lua').new_set()

T['草稿跨模块重载恢复且不同 worktree 互不覆盖'] = function()
  child.lua_func(function()
    local root = assert(vim.env.VV_TEST_TMP)
    local a, b = root .. '/repo', root .. '/worktree'
    vim.fn.mkdir(a, 'p')
    vim.fn.mkdir(b, 'p')
    local Prompt = require('vv-git.left.prompt')
    local lines = { 'feat: 保留草稿', '', '  多行正文  ' }
    Prompt.open({ git_root = a, has_staged = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    -- 模拟外部关窗，而不是只覆盖插件自己的 close 路径
    vim.api.nvim_win_close(0, true)
    package.loaded['vv-git.left.prompt'] = nil
    Prompt = require('vv-git.left.prompt')
    Prompt.open({ git_root = b, has_staged = true })
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '' }), '另一 worktree 不应恢复父仓库草稿')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '另一个草稿' })
    Prompt.close()
    Prompt.open({ git_root = a, has_staged = true })
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), lines), '重新加载后应从磁盘恢复原始多行内容')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '  ' })
    Prompt.close()
    Prompt.open({ git_root = a, has_staged = true })
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '' }), '主动清空后不应复活旧草稿')
    Prompt.close()
  end)
end

T['正常退出时保存并由全新进程恢复'] = function()
  child.lua_func(function()
    local root = assert(vim.env.VV_TEST_TMP)
    local script = root .. '/restart.lua'
    local function run(body)
      vim.fn.writefile({
        "vim.opt.runtimepath:prepend(assert(vim.env.VV_UTILS))",
        "vim.opt.runtimepath:prepend(assert(vim.env.VV_TEST_REPO))",
        "local Prompt = require('vv-git.left.prompt')",
        "Prompt.open({ git_root = assert(vim.env.VV_TEST_TMP), has_staged = true })",
        body,
        "vim.cmd('qa!')",
      }, script)
      local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', script },
        { text = true }):wait(10000)
      assert(result.code == 0, '隔离进程执行失败：' .. (result.stderr or ''))
    end
    run("vim.api.nvim_buf_set_lines(0, 0, -1, false, { '退出前的草稿', '', '正文' })")
    run("assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '退出前的草稿', '', '正文' }), '重启后草稿丢失')")
  end)
end

T['失败保留草稿且成功只清除本次消息'] = function()
  child.lua_func(function()
    local Prompt = require('vv-git.left.prompt')
    local Git = require('vv-git.git')
    local root = assert(vim.env.VV_TEST_TMP)
    local callback
    Git.commit = function(_, msg, cb)
      assert(msg == '测试提交', '提交应使用恢复的消息')
      callback = cb
    end
    vim.notify = function() end
    Prompt.open({ git_root = root, has_staged = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '测试提交' })
    vim.fn.maparg('<C-s>', 'i', false, true).callback()
    callback(false, 'hook failed')
    Prompt.close()
    Prompt.open({ git_root = root, has_staged = true })
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '测试提交' }), '提交失败后应恢复草稿')
    vim.fn.maparg('<C-s>', 'i', false, true).callback()
    callback(true)
    Prompt.open({ git_root = root, has_staged = true })
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '' }), '提交成功后应清空草稿')
    Prompt.close()
  end)
end

return T
