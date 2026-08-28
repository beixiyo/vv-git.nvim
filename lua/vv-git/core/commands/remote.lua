-- 远端命令：push、pull 和首次发布分支

local State = require('vv-git.state')
local Git = require('vv-git.git')

local M = {}

---@param context table
---@return table
function M.new(context)
  local commands = {}
  local controller = context.controller

  local git_net = State.guarded(function(state, action)
    if not state.git_root then return end

    local owner_root = state.git_root
    local owner_generation = State.root_generation(state)
    local root = context.cursor_root(state)

    if not root then return end

    local request = context.request_scope:begin({ key = 'net:' .. action })
    local fn = Git[action]

    vim.notify('[vv-git] ' .. action .. '...', vim.log.levels.INFO)

    local cancel = fn(root, function(ok, out)
      local refresh = request:finish() and context.owns_state(state, owner_root, owner_generation)
      local reason = request:reason()

      if reason ~= 'finished' and reason ~= 'invalidated' and reason ~= 'owner-invalidated' then return end

      local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
      local prefix = ok and ('[vv-git] ' .. action .. ' succeeded') or ('[vv-git] ' .. action .. ' failed')

      vim.notify(prefix .. (out and ('\n' .. out) or ''), level)
      if ok and refresh then controller.refresh() end
    end)
    if type(cancel) == 'function' then request:set_cancel(cancel) end
  end)

  function commands._push() git_net('push') end
  function commands._pull() git_net('pull') end

  commands._publish = State.guarded(function(state)
    if not state.git_root then return end

    local owner_root = state.git_root
    local owner_generation = State.root_generation(state)
    local root = context.cursor_root(state)

    if not root then return end

    local request = context.request_scope:begin({ key = 'publish' })
    local add_cancel, cancel_all = context.new_cancel_bag()
    request:set_cancel(cancel_all)

    local function current()
      return context.owns_context(request, state, owner_root, owner_generation)
    end

    local function stop()
      request:dispose()
    end

    add_cancel(Git.repo_info(root, function(info, err)
      if not current() then return end
      if not info then
        stop()
        vim.notify('[vv-git] failed to inspect repository\n' .. (err or 'unknown error'), vim.log.levels.ERROR)
        return
      end

      if info.detached then
        stop()
        vim.notify('[vv-git] Detached HEAD. Create or switch to a branch before publishing.', vim.log.levels.WARN)
        return
      end

      if info.unborn or not info.head then
        stop()
        vim.notify('[vv-git] Commit the branch before publishing.', vim.log.levels.WARN)
        return
      end

      if info.upstream then
        stop()
        vim.notify('[vv-git] Already tracking ' .. info.upstream .. '. Use p to push.', vim.log.levels.INFO)
        return
      end

      local function publish_to(remote, remote_added)
        if not current() then return end
        vim.notify('[vv-git] Publishing ' .. info.branch_name .. ' to ' .. remote .. '...', vim.log.levels.INFO)

        add_cancel(Git.publish(root, remote, function(ok, out)
          if not request:finish()
              or not State.is_current(state)
              or state.git_root ~= owner_root
              or State.root_generation(state) ~= owner_generation then
            return
          end

          local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
          local prefix = ok
              and ('[vv-git] Published ' .. info.branch_name .. ' to ' .. remote)
              or ('[vv-git] Publish failed' .. (remote_added and ' (origin was added)' or ''))
          vim.notify(prefix .. (out and ('\n' .. out) or ''), level)

          if ok or remote_added then
            state._block_hint = root
            controller.refresh()
          end
        end))
      end

      local function choose_existing_remote()
        for _, remote in ipairs(info.remotes) do
          if remote == 'origin' then publish_to('origin', false); return end
        end
        if #info.remotes == 1 then publish_to(info.remotes[1], false); return end

        vim.ui.select(info.remotes, { prompt = 'Publish ' .. info.branch_name .. ' to remote:' }, function(remote)
          if not current() then return end
          if remote then
            publish_to(remote, false)
          else
            stop()
          end
        end)
      end

      if #info.remotes > 0 then
        choose_existing_remote()
        return
      end

      vim.ui.input({ prompt = 'Remote URL for origin: ' }, function(url)
        if not current() then return end

        url = url and vim.trim(url) or ''
        if url == '' then stop(); return end

        add_cancel(Git.add_remote(root, 'origin', url, function(ok, out)
          if not current() then return end
          if not ok then
            stop()
            vim.notify('[vv-git] Add origin failed' .. (out and ('\n' .. out) or ''), vim.log.levels.ERROR)
            return
          end

          publish_to('origin', true)
        end))
      end)
    end))
  end)

  return commands
end

return M
