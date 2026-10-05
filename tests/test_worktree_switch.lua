-- 收集阶段只注册场景；每个场景由独立子进程执行。
local T, child = dofile('tests/helpers.lua').new_set()

T['成功切换才提交目标标签目录，重载前清除旧内容'] = function()
  child.lua_func(function()
    allowed_errors[#allowed_errors + 1] = '[vv-git] Could not enter worktree: vv-git tab is no longer valid'
    -- Worktree 切换仅在 tab-local cwd 成功变更后提交到状态


    local Commands = require('vv-git.core.commands')
    local Loader = require('vv-git.loader')
    local State = require('vv-git.state')
    local Worktree = require('vv-git.worktree')

    local tmp = vim.fn.tempname()
    local old_root = tmp .. '/old'
    local new_root = tmp .. '/new'
    vim.fn.mkdir(old_root, 'p')
    vim.fn.mkdir(new_root, 'p')

    local original_open_manager = Worktree.open_manager
    local original_reload = Loader.reload_index
    Worktree.open_manager = function(_, on_select) on_select({ path = new_root }) end
    local reload_lines
    Loader.reload_index = function(state)
      state._reloaded = true
      if state.panel then reload_lines = vim.api.nvim_buf_get_lines(state.panel.buf, 0, -1, false) end
    end

    local commands = Commands.new({
      controller = {},
      config = function() return { worktree = {} } end,
    })

    State.clear()
    local state = State.create()
    state.git_root = old_root
    local source_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd.tcd(vim.fn.fnameescape(old_root))
    vim.cmd('tabnew')
    local target_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd.tcd(vim.fn.fnameescape(old_root))
    vim.api.nvim_set_current_tabpage(source_tab)
    state.tabpage = target_tab
    state.folds = {}
    state.section_folds = {}
    state.block_folds = {}
    state.selection = {}
    -- 面板正显示旧 worktree 的分支与文件树
    local panel_buf = require('vv-git.left.panel').create_buf()
    state.panel = { buf = panel_buf }
    state.branch = 'old-branch'
    state.repo_info = { branch = 'old-branch', branch_name = 'old-branch', head = 'abc', ahead = 0, behind = 0, remotes = {} }
    state.tree = require('vv-git.tree').build({ [old_root .. '/old-file.txt'] = ' M' }, old_root)
    require('vv-git.left.render').render(state)
    assert(table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), '\n'):find('old-file.txt', 1, true),
      '前置：面板应先显示旧 worktree 的文件')
    commands._worktree_pick()
    assert(state.git_root == new_root, '成功 tcd 后新 root 已提交')
    local shown = table.concat(reload_lines or {}, '\n')
    assert(not shown:find('old-file.txt', 1, true) and not shown:find('old-branch', 1, true)
        and shown:find('Waiting for git status', 1, true),
      'reload 期间面板应显示等待骨架，不再显示旧 worktree 的分支与文件树: ' .. shown)
    state.panel = nil
    assert(vim.uv.fs_realpath(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(state.tabpage)))
        == vim.uv.fs_realpath(new_root), '切换仅影响目标 tab 的 cwd')
    assert(vim.uv.fs_realpath(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(source_tab)))
        == vim.uv.fs_realpath(old_root), '切换保留发起 tab 的 cwd')
    assert(state._reloaded == true, '成功切换会重载新 root')

    state.git_root = old_root
    state._reloaded = nil
    vim.cmd('tabnew')
    local invalid_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd('tabclose')
    state.tabpage = invalid_tab
    commands._worktree_pick()
    assert(state.git_root == old_root, 'tablocal tcd 失败时保持旧 root')
    assert(state._reloaded == nil, '失败切换不会重载未提交上下文')

    -- vv-explorer 切根跟随：同样先清掉旧仓库内容再 reload
    local external_root = tmp .. '/external'
    vim.fn.mkdir(external_root, 'p')
    vim.fn.system({ 'git', 'init', '-q', external_root })
    external_root = vim.fs.normalize(vim.uv.fs_realpath(external_root))
    state.git_root = old_root
    state._reloaded = nil
    reload_lines = nil
    state.panel = { buf = panel_buf }
    state.branch = 'old-branch'
    state.subrepos = {}
    state.tree = require('vv-git.tree').build({ [old_root .. '/old-file.txt'] = ' M' }, old_root)
    require('vv-git.left.render').render(state)
    local lifecycle = require('vv-git.core.lifecycle').new({
      controller = {},
      config = function() return {} end,
      track_panel_width = function() end,
      persist_panel_width = function() end,
    })
    lifecycle._follow_external_root(external_root)
    assert(vim.wait(5000, function() return state._reloaded == true end, 10), '跟随外部根应重载新仓库')
    assert(state.git_root == external_root, '跟随外部根应提交新 root')
    shown = table.concat(reload_lines or {}, '\n')
    assert(not shown:find('old-file.txt', 1, true) and not shown:find('old-branch', 1, true)
        and shown:find('Waiting for git status', 1, true),
      '跟随外部根 reload 期间不应显示旧仓库内容: ' .. shown)
    state.panel = nil

    Worktree.open_manager = original_open_manager
    Loader.reload_index = original_reload
    State.clear()
    if vim.api.nvim_tabpage_is_valid(target_tab) then
      vim.api.nvim_set_current_tabpage(target_tab)
      vim.cmd('tabclose')
    end
    vim.fn.delete(tmp, 'rf')
  end)
end

return T
