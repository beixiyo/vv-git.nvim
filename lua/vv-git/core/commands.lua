-- git 命令操作：commit / push / pull / compare / goto_file / yank_abs_path

local State = require('vv-git.state')
local Git = require('vv-git.git')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Prompt = require('vv-git.left.prompt')
local Editor = require('vv-utils.editor')
local Keymaps = require('vv-git.core.keymaps')

local L = {}

-- commit / push / pull 是单仓库操作：路由到 panel 光标所在节点的所属仓库
-- （「对你正看着的仓库下手」，可预测）；光标不在任何节点上则回退父仓库根
---@param state table
---@return string root
local function cursor_root(state)
  local id = Keymaps.id_under_cursor(state)
  return (id and id.root) or state.git_root
end

---@param M table
---@param path string
---@return boolean
local function is_binary(M, path)
  local cfg = M._config.binary
  if not cfg or not cfg.intercept then return false end
  local ext = path:match('%.([%w_]+)$')
  return ext and cfg.extensions[ext:lower()] or false
end

---@param M table
function L.attach(M)
  M._compare_pick = State.guarded(function(state)
    if not state.git_root then return end
    local Compare = require('vv-git.compare')
    Compare.open_picker(state, function(hash, short, label)
      Compare.start(state, hash, short, label, function()
        state.selection = {}
        RightView.close(state)
        LeftRender.render(state)
      end)
    end)
  end)

  M._compare_ref = State.guarded(function(state, ref)
    M._compare_refs(ref, 'HEAD')
  end)

  M._compare_refs = State.guarded(function(state, from_ref, to_ref, on_ready, on_error)
    if not state.git_root or not from_ref or from_ref == '' or not to_ref or to_ref == '' then return end
    local Compare = require('vv-git.compare')
    Compare.start_refs(state, from_ref, to_ref, from_ref:sub(1, 7), from_ref .. '..' .. to_ref, function()
      state.selection = {}
      RightView.close(state)
      LeftRender.render(state)
      M._invoke_callback(on_ready, M._context(state))
    end, function(message)
      M._invoke_callback(on_error, message)
    end)
  end)

  M._compare_stop = State.guarded(function(state)
    if not state.compare then return false end
    require('vv-git.compare').stop(state)
    state.selection = {}
    RightView.close(state)
    LeftRender.render(state)
    return true
  end)

  M._commit_show_pick = State.guarded(function(state)
    if not state.git_root then return end
    local Compare = require('vv-git.compare')
    Compare.open_picker(state, function(hash, short, label)
      Compare.start_commit(state, hash, short, label, function()
        state.selection = {}
        RightView.close(state)
        LeftRender.render(state)
      end)
    end)
  end)

  -- 展示指定 commit 的 diff（hash 由外部选好，跳过 open_picker）。供公开 M.show_commit / 外部集成（telescope git_log 等）用
  M._commit_show = State.guarded(function(state, hash, on_ready, on_error)
    if not state.git_root or not hash or hash == '' then return end
    local Compare = require('vv-git.compare')
    local short = hash:sub(1, 7)
    local subject = vim.fn.system({ 'git', '-C', state.git_root, 'log', '-1', '--format=%s', hash })
    subject = vim.v.shell_error == 0 and vim.trim(subject) or ''
    local label = subject ~= '' and (short .. '  ' .. subject) or short
    Compare.start_commit(state, hash, short, label, function()
      state.selection = {}
      RightView.close(state)
      LeftRender.render(state)
      M._invoke_callback(on_ready, M._context(state))
    end, function(message)
      M._invoke_callback(on_error, message)
    end)
  end)

  -- 列出所有 worktree → 选中即把面板切到该 worktree 看它的 diff
  M._worktree_pick = State.guarded(function(state)
    if not state.git_root then return end
    local Worktree = require('vv-git.worktree')
    Worktree.open_picker(state, function(wt)
      local target = vim.fs.normalize(wt.path)
      if target == state.git_root then
        vim.notify('[vv-git] Already on this worktree', vim.log.levels.INFO)
        return
      end
      if vim.fn.isdirectory(target) == 0 then
        vim.notify('[vv-git] worktree path does not exist (maybe pruned): ' .. target, vim.log.levels.ERROR)
        return
      end

      -- 一次干净的上下文切换：切 root，清掉随旧 root 失效的瞬态（选中/比较/折叠/右视图），
      -- tcd 到该 worktree（tab-local，只影响 vv-git 专属 tab，不污染来时 tab），reload 后即展示其 diff
      state.git_root = target
      state.cur_path = nil
      state.selection = {}
      state.folds = {}
      state.section_folds = {}
      state.block_folds = {}
      require('vv-git.compare').stop(state)
      pcall(vim.cmd.tcd, vim.fn.fnameescape(target))
      RightView.close(state)
      require('vv-git.loader').reload_index(state)
    end)
  end)

  M._commit = State.guarded(function(state)
    if not state.git_root then return end
    local root = cursor_root(state)
    Git.has_staged(root, function(has)
      local function open_prompt()
        Prompt.open({
          git_root = root,
          has_staged = has,
          on_success = function()
            state._block_hint = root
            M.refresh()
          end,
        })
      end
      if has then
        open_prompt()
      else
        vim.ui.select({ 'Commit ALL working tree', 'Cancel' }, {
          prompt = 'No staged changes. Commit all working tree changes instead?',
        }, function(choice)
          if choice == 'Commit ALL working tree' then open_prompt() end
        end)
      end
    end)
  end)

  local git_net = State.guarded(function(state, action)
    if not state.git_root then return end
    local root = cursor_root(state)
    local fn = Git[action]
    vim.notify('[vv-git] ' .. action .. '...', vim.log.levels.INFO)
    fn(root, function(ok, out)
      local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
      local prefix = ok and ('[vv-git] ' .. action .. ' succeeded') or ('[vv-git] ' .. action .. ' failed')
      vim.notify(prefix .. (out and ('\n' .. out) or ''), level)
      if ok then M.refresh() end
    end)
  end)

  function M._push() git_net('push') end
  function M._pull() git_net('pull') end

  M._publish = State.guarded(function(state)
    if not state.git_root then return end
    local root = cursor_root(state)

    Git.repo_info(root, function(info, err)
      if not State.is_current(state) then return end
      if not info then
        vim.notify('[vv-git] failed to inspect repository\n' .. (err or 'unknown error'), vim.log.levels.ERROR)
        return
      end
      if info.detached then
        vim.notify('[vv-git] Detached HEAD. Create or switch to a branch before publishing.', vim.log.levels.WARN)
        return
      end
      if info.unborn or not info.head then
        vim.notify('[vv-git] Commit the branch before publishing.', vim.log.levels.WARN)
        return
      end
      if info.upstream then
        vim.notify('[vv-git] Already tracking ' .. info.upstream .. '. Use p to push.', vim.log.levels.INFO)
        return
      end

      local function publish_to(remote, remote_added)
        vim.notify('[vv-git] Publishing ' .. info.branch_name .. ' to ' .. remote .. '...', vim.log.levels.INFO)
        Git.publish(root, remote, function(ok, out)
          local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
          local prefix = ok
              and ('[vv-git] Published ' .. info.branch_name .. ' to ' .. remote)
              or ('[vv-git] Publish failed' .. (remote_added and ' (origin was added)' or ''))
          vim.notify(prefix .. (out and ('\n' .. out) or ''), level)
          if (ok or remote_added) and State.is_current(state) then
            state._block_hint = root
            M.refresh()
          end
        end)
      end

      local function choose_existing_remote()
        for _, remote in ipairs(info.remotes) do
          if remote == 'origin' then publish_to('origin', false); return end
        end
        if #info.remotes == 1 then publish_to(info.remotes[1], false); return end

        vim.ui.select(info.remotes, { prompt = 'Publish ' .. info.branch_name .. ' to remote:' }, function(remote)
          if remote and State.is_current(state) then publish_to(remote, false) end
        end)
      end

      if #info.remotes > 0 then
        choose_existing_remote()
        return
      end

      vim.ui.input({ prompt = 'Remote URL for origin: ' }, function(url)
        if not State.is_current(state) then return end
        url = url and vim.trim(url) or ''
        if url == '' then return end
        Git.add_remote(root, 'origin', url, function(ok, out)
          if not ok then
            vim.notify('[vv-git] Add origin failed' .. (out and ('\n' .. out) or ''), vim.log.levels.ERROR)
            return
          end
          publish_to('origin', true)
        end)
      end)
    end)
  end)

  M._goto_file = State.guarded(function(state)
    local cur_win = vim.api.nvim_get_current_win()
    local view = state.view
    local abspath, row = nil, nil

    if view and view.path
        and (cur_win == view.a_win or cur_win == view.b_win) then
      abspath = (view.root or state.git_root) .. '/' .. view.path
      if view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
        row = vim.api.nvim_win_get_cursor(view.b_win)[1]
      end
    else
      local id = Keymaps.id_under_cursor(state)
      if not id or not id.node or id.node.is_dir then return end
      abspath = (id.root or state.git_root) .. '/' .. id.node.relpath
    end

    if is_binary(M, abspath) then
      require('vv-utils.sys').open_default(abspath)
      return
    end

    M.close()

    local win = vim.api.nvim_get_current_win()
    if vim.wo[win].winfixbuf then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not vim.wo[w].winfixbuf and vim.api.nvim_win_get_config(w).relative == '' then
          vim.api.nvim_set_current_win(w)
          break
        end
      end
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
    if row then
      -- rev/compare 视图行数可能多于工作区文件，clamp 防越界（否则 set_cursor 静默失效，光标落第 1 行）
      row = math.min(row, vim.api.nvim_buf_line_count(0))
      pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
      pcall(vim.cmd, 'normal! zz')
    end
  end)

  M._yank_abs_path = State.guarded(function(state)
    if not state.git_root then return end
    local cur_win = vim.api.nvim_get_current_win()
    local view = state.view
    local relpath, root

    if view and view.path
        and (cur_win == view.a_win or cur_win == view.b_win) then
      relpath = view.path
      root = view.root
    else
      local id = Keymaps.id_under_cursor(state)
      if not id or not id.node then return end
      relpath = id.node.relpath
      root = id.root
    end

    local abs = vim.fs.normalize((root or state.git_root) .. '/' .. relpath)
    Editor.copy_path({ path = abs, title = 'vv-git' })
  end)

  M._system_open = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id or not id.node then return end
    local abspath = vim.fs.normalize((id.root or state.git_root) .. '/' .. id.node.relpath)
    require('vv-utils.sys').open_default(abspath)
  end)

  M._execute = State.guarded(function(state)
    local id = Keymaps.id_under_cursor(state)
    if not id or not id.node or id.node.is_dir then return end
    local abspath = vim.fs.normalize((id.root or state.git_root) .. '/' .. id.node.relpath)

    local plan, err = require('vv-utils.exec').resolve(abspath)
    if not plan then
      vim.notify('vv-git: ' .. (err or 'cannot run ' .. abspath), vim.log.levels.WARN)
      return
    end

    local prompt = 'vv-git execute?\n  ' .. table.concat(plan.cmd, ' ')
    if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then return end

    vim.cmd('botright 15new')
    if vim.fn.has('nvim-0.11') == 1 then
      vim.fn.jobstart(plan.cmd, { term = true, cwd = vim.fs.dirname(abspath) })
    else
      vim.fn.termopen(plan.cmd, { cwd = vim.fs.dirname(abspath) })
    end
    vim.cmd('startinsert')
  end)
end

return L
