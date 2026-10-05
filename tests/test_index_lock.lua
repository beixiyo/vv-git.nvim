-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['真实索引路径与取消预检，锁文件始终保留'] = function()
  child.lua_func(function()
    -- Git index 写入集成回归：解析真实 index 路径，但绝不自动删除锁文件


    local repo = vim.fn.tempname()
    local original_index_file = vim.env.GIT_INDEX_FILE
    local IndexLock = require('vv-git.index_lock')
    local original_ensure_available = IndexLock.ensure_available

    local function cleanup()
      vim.env.GIT_INDEX_FILE = original_index_file
      IndexLock.ensure_available = original_ensure_available
      vim.fn.delete(repo, 'rf')
    end

    local function git(args)
      local command = { 'git', '-C', repo }
      vim.list_extend(command, args)
      local output = vim.fn.system(command)
      assert(vim.v.shell_error == 0, output)
      return output
    end

    local function wait_call(fn, ...)
      local done, ok, err
      local args = { ... }
      args[#args + 1] = function(result, message)
        done, ok, err = true, result, message
      end
      fn(unpack(args))
      assert(vim.wait(3000, function() return done end), 'Git 操作超时')
      return ok, err
    end

    local function stage(path)
      return wait_call(require('vv-git.git').stage, repo, { path })
    end

    local function assert_locked(operation, ...)
      local ok, err = wait_call(operation, repo, ...)
      assert(not ok, '操作应因已存在锁而拒绝')
      assert(type(err) == 'string' and err:match('Git index'),
        '锁拒绝应包含非空锁错误信息: ' .. tostring(err))
    end

    local function write_lock(path, lines, timestamp)
      vim.fn.writefile(lines, path)
      if timestamp then assert(vim.uv.fs_utime(path, timestamp, timestamp)) end
    end

    local function run()
      vim.fn.mkdir(repo, 'p')

      -- 不让调用方的备用索引泄漏进仓库初始化
      vim.env.GIT_INDEX_FILE = nil
      git({ 'init', '-q' })
      local git_dir = vim.fn.system({ 'git', '-C', repo, 'rev-parse', '--absolute-git-dir' })
      assert(vim.v.shell_error == 0, git_dir)
      git_dir = git_dir:gsub('[\r\n]+$', '')

      -- 无覆盖配置时生产暂存接口使用 Git 默认索引
      vim.fn.writefile({ 'default' }, repo .. '/default.txt')
      local ok, err = stage('default.txt')
      assert(ok, err)
      assert(vim.uv.fs_stat(git_dir .. '/index'), '默认 Git index 未写入')

      -- 索引预检尚在等待时请求可被失效
      -- 写入者仅报告一次取消，且不改变索引或历史
      local pending_preflight
      local owner_current = true
      IndexLock.ensure_available = function(_, callback)
        pending_preflight = callback
      end

      vim.fn.writefile({ 'pending stage' }, repo .. '/pending-stage.txt')
      local staged_before = git({ 'diff', '--cached', '--name-only' })
      local stage_all_callbacks = 0
      local stage_all_ok
      require('vv-git.git').stage_all(repo, function(result)
        stage_all_callbacks = stage_all_callbacks + 1
        stage_all_ok = result
      end, { is_current = function() return owner_current end })
      assert(vim.wait(3000, function() return type(pending_preflight) == 'function' end),
        'stage_all 应等待 index 预检完成')
      owner_current = false
      pending_preflight(true)
      assert(stage_all_callbacks == 1 and stage_all_ok == false,
        '取消的 stage_all 回调应只触发一次且失败')
      assert(git({ 'diff', '--cached', '--name-only' }) == staged_before,
        '取消的 stage_all 不应修改 index')

      local head_before = vim.fn.system({ 'git', '-C', repo, 'rev-parse', '--verify', 'HEAD' })
      assert(vim.v.shell_error ~= 0, 'fixture 应从无提交状态开始')
      local commit_callbacks = 0
      local commit_ok
      pending_preflight = nil
      require('vv-git.git').commit(repo, 'cancelled commit', function(result)
        commit_callbacks = commit_callbacks + 1
        commit_ok = result
      end, { is_current = function() return owner_current end })
      assert(vim.wait(3000, function() return type(pending_preflight) == 'function' end),
        'commit 应等待 index 预检完成')
      pending_preflight(true)
      assert(commit_callbacks == 1 and commit_ok == false,
        '取消的 commit 回调应只触发一次且失败')
      local head_after = vim.fn.system({ 'git', '-C', repo, 'rev-parse', '--verify', 'HEAD' })
      assert(vim.v.shell_error ~= 0 and head_after == head_before,
        '取消的 commit 不应创建提交')

      IndexLock.ensure_available = original_ensure_available

      -- 带末尾空格的绝对索引路径必须原样保留
      vim.fn.mkdir(repo .. '/absolute', 'p')
      local absolute_index = repo .. '/absolute/index '
      vim.env.GIT_INDEX_FILE = absolute_index
      vim.fn.writefile({ 'absolute' }, repo .. '/absolute.txt')
      ok, err = stage('absolute.txt')
      assert(ok, err)
      assert(vim.uv.fs_stat(absolute_index), '绝对 GIT_INDEX_FILE 未被写入')
      local absolute_lock = absolute_index .. '.lock'
      write_lock(absolute_lock, { 'owned' })
      assert_locked(require('vv-git.git').stage, { 'absolute-locked.txt' })
      assert(vim.uv.fs_stat(absolute_lock), '绝对锁文件应保留')

      -- 带末尾空格的相对索引路径按指定仓库根解析
      vim.fn.mkdir(repo .. '/relative', 'p')
      local relative_index = 'relative/index '
      local relative_index_abs = repo .. '/' .. relative_index
      vim.env.GIT_INDEX_FILE = relative_index
      vim.fn.writefile({ 'relative' }, repo .. '/relative.txt')
      ok, err = stage('relative.txt')
      assert(ok, err)
      assert(vim.uv.fs_stat(relative_index_abs), '相对 GIT_INDEX_FILE 未被写入')
      local lock = relative_index_abs .. '.lock'
      local old = os.time() - 120

      -- 新建空锁仍活跃，不可删除或绕过
      write_lock(lock, {})
      ok, err = stage('fresh.txt')
      assert(not ok and err:match('Git index is locked'), '空锁应被拒绝')
      assert(vim.uv.fs_stat(lock), '空锁应被保留')

      -- 过期空锁只报告手动恢复，不自动删除
      write_lock(lock, {}, old)
      ok, err = stage('stale.txt')
      assert(not ok and err:match('stale') and err:match('manually'),
        '过期空锁应要求手动移除')
      assert(vim.uv.fs_stat(lock), '过期空锁应被保留')

      -- 非空锁同样被拒绝并保留
      write_lock(lock, { 'owned' })
      vim.fn.writefile({ 'three' }, repo .. '/three.txt')
      ok, err = stage('three.txt')
      assert(not ok and err:match('Git index is locked'), '非空锁应被拒绝')
      assert(vim.uv.fs_stat(lock), '非空锁应被保留')

      -- 所有索引写入操作使用同一预检
      assert_locked(require('vv-git.git').stage_all)
      assert_locked(require('vv-git.git').unstage, { 'relative.txt' })
      assert_locked(require('vv-git.git').commit, 'blocked commit')
      assert_locked(require('vv-git.git').accept_ours, { 'relative.txt' })
      assert_locked(require('vv-git.git').accept_theirs, { 'relative.txt' })

      -- 锁消失后生产 Git 接口正常继续
      vim.fn.delete(lock)
      vim.fn.writefile({ 'after-unlock' }, repo .. '/after-unlock.txt')
      ok, err = stage('after-unlock.txt')
      assert(ok, err)
    end

    local ok, err = xpcall(run, debug.traceback)
    cleanup()
    if not ok then error(err) end
  end)
end

return T
