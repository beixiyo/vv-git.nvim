-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['真实丢弃同步已打开文档且保留未保存修改'] = function()
  child.lua_func(function()
    -- discard 之后已打开 buffer 的同步：真实 Git 仓库 + 真实 buffer + 记录通知的假 LSP
    --
    -- 复现的真实场景：explorer 把 src/q.ts 剪切到 hooks/q.ts（buffer 随之改名），随后在 vv-git 里丢弃这次改动
    -- 被删掉的 hooks/q.ts 若还留着已加载的 buffer，LSP 会一直把它当成客户端打开的文档，影响之后的重命名结果
    -- 契约：未修改、文件已被删的 buffer 关闭并发 didClose；被还原的未修改 buffer 重新加载为还原后的内容；
    -- 已修改的 buffer 不关闭、不重载、内容原样

    vim.cmd('filetype plugin on')
    vim.o.autoread = true

    package.loaded['vv-utils.confirm'] = {
      open = function(opts)
        vim.schedule(opts.on_confirm)
        return { close = function() end }
      end,
    }

    local State = require('vv-git.state')
    local Discard = require('vv-git.left.discard')

    local events = {}
    vim.lsp.config('vv_fake_discard', {
      cmd = function()
        local id = 0
        return {
          request = function(method, _, callback)
            if method == 'initialize' then
              callback(nil, { capabilities = { textDocumentSync = { openClose = true, change = 2 } } })
            elseif method == 'shutdown' then
              callback(nil, nil)
            end
            id = id + 1
            return true, id
          end,
          notify = function(method, params)
            local td = params and params.textDocument
            events[#events + 1] = { method = method, uri = td and td.uri }
            return true
          end,
          is_closing = function() return false end,
          terminate = function() end,
        }
      end,
      filetypes = { 'typescript' },
    })
    vim.lsp.enable('vv_fake_discard')

    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo .. '/src', 'p')
    vim.fn.mkdir(repo .. '/hooks', 'p')
    repo = assert(vim.uv.fs_realpath(repo))
    local function git(...) vim.fn.system(vim.list_extend({ 'git', '-C', repo }, { ... })) end
    git('init', '-q')
    git('config', 'user.email', 'vv-git@example.invalid')
    git('config', 'user.name', 'vv-git test')
    vim.fn.writefile({ 'export const q = 1' }, repo .. '/src/q.ts')
    vim.fn.writefile({ 'export const a = 1' }, repo .. '/src/a.ts')
    vim.fn.writefile({ 'export const b = 1' }, repo .. '/src/b.ts')
    git('add', '.')
    git('commit', '-qm', 'fixture')

    local function open(path)
      vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      assert(vim.wait(2000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 1 end), '前置：LSP 应附着 ' .. path)
      return buf
    end

    -- 模拟剪切：src/q.ts 移到 hooks/q.ts，buffer 指向新路径
    assert(vim.uv.fs_rename(repo .. '/src/q.ts', repo .. '/hooks/q.ts'))
    local moved = open(repo .. '/hooks/q.ts')
    -- 被 LSP 改写过并保存的 tracked 文件，buffer 已加载且未修改
    vim.fn.writefile({ 'export const a = 2' }, repo .. '/src/a.ts')
    local rewritten = open(repo .. '/src/a.ts')
    -- 用户在未跟踪文件里还有未保存的修改
    vim.fn.writefile({ 'draft' }, repo .. '/hooks/dirty.ts')
    local dirty = open(repo .. '/hooks/dirty.ts')
    vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { 'unsaved work' })
    -- 被还原的 tracked 文件，buffer 有未保存修改：checktime 会弹阻塞的 W12，绝不能对它 checktime
    vim.fn.writefile({ 'export const b = 2' }, repo .. '/src/b.ts')
    local dirty_tracked = open(repo .. '/src/b.ts')
    vim.api.nvim_buf_set_lines(dirty_tracked, 0, -1, false, { 'my edit' })
    vim.cmd('enew')

    State.clear()
    local state = State.create()
    state.git_root = repo
    -- git restore 精度是秒级 mtime，确保还原后的 mtime 与 buffer 加载时不同，checktime 才能察觉
    vim.uv.sleep(1100)

    events = {}
    local done = false
    Discard.confirm(state, { { root = repo, tracked = { 'src/q.ts', 'src/a.ts', 'src/b.ts' }, untracked = { 'hooks/q.ts', 'hooks/dirty.ts' } } }, {
      title = 'Discard', message = 'Discard', severity = 'danger',
      after = function() done = true end,
    })
    assert(vim.wait(5000, function() return done end, 10), 'discard 应完成')
    vim.wait(200)

    assert(vim.uv.fs_stat(repo .. '/src/q.ts') and not vim.uv.fs_stat(repo .. '/hooks/q.ts'), '前置：discard 应还原旧文件、删除新文件')

    assert(not vim.api.nvim_buf_is_valid(moved), '被删文件的未修改 buffer 必须关闭，否则 LSP 会一直认为它被打开着')
    local closed = false
    for _, e in ipairs(events) do
      if e.method == 'textDocument/didClose' and e.uri == vim.uri_from_fname(repo .. '/hooks/q.ts') then closed = true end
    end
    assert(closed, 'LSP 服务端应收到被删文件的 didClose')

    assert(vim.api.nvim_buf_get_lines(rewritten, 0, -1, false)[1] == 'export const a = 1',
      '被还原的未修改 buffer 应重新加载为还原后的内容，实际 ' .. vim.inspect(vim.api.nvim_buf_get_lines(rewritten, 0, -1, false)))

    assert(vim.api.nvim_buf_is_loaded(dirty) and vim.bo[dirty].modified, '已修改的 buffer 不能被关闭')
    assert(vim.api.nvim_buf_get_lines(dirty, 0, -1, false)[1] == 'unsaved work', '已修改 buffer 的内容必须原样保留')

    assert(vim.bo[dirty_tracked].modified and vim.api.nvim_buf_get_lines(dirty_tracked, 0, -1, false)[1] == 'my edit',
      '被还原文件的已修改 buffer 不能被重载，内容原样')

    vim.lsp.enable('vv_fake_discard', false)
    for _, client in ipairs(vim.lsp.get_clients()) do client:stop(true) end
    vim.fn.delete(repo, 'rf')
  end)
end

return T
