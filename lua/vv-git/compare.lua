-- compare.lua — 比较模式：选分支 → 选 commit → diff commit..HEAD
-- state.compare = { commit, short, label, files }
-- files: { status='M'|'A'|'D'|'R'|'C', path, old_path? }[]

local M = {}

local Git = require('vv-git.git')
local State = require('vv-git.state')

local function begin_request(state)
  local request = (state._compare_req_id or 0) + 1
  state._compare_req_id = request
  return request, state.git_root
end

local function is_current(state, request, root)
  return State.is_current(state)
    and state._compare_req_id == request
    and state.git_root == root
end

---@param c {hash:string, short:string, subject:string}
---@return string
local function commit_display(c)
  local subj = c.subject
  if #subj > 60 then subj = subj:sub(1, 57) .. '...' end
  return c.short .. '  ' .. subj
end

-- 打开两级选择器：分支 → commit，选完后 cb(hash, short, label)
---@param state table
---@param cb fun(hash:string, short:string, label:string)
function M.open_picker(state, cb)
  if not state.git_root then return end
  local request, root = begin_request(state)

  Git.branches(root, function(branches, err)
    if not is_current(state, request, root) then return end
    if not branches or #branches == 0 then
      vim.notify('[vv-git] ' .. (err or 'No branches found'), vim.log.levels.WARN)
      return
    end

    vim.ui.select(branches, {
      prompt = 'Compare HEAD with commit from branch:',
    }, function(branch)
      if not branch then return end

      Git.log(root, branch, 50, function(commits, lerr)
        if not is_current(state, request, root) then return end
        if not commits or #commits == 0 then
          vim.notify('[vv-git] ' .. (lerr or 'No commits on ' .. branch), vim.log.levels.WARN)
          return
        end

        local labels = {}
        for _, c in ipairs(commits) do
          labels[#labels + 1] = commit_display(c)
        end

        vim.ui.select(labels, {
          prompt = 'Select commit (' .. branch .. '):',
        }, function(_, idx)
          if not is_current(state, request, root) then return end
          if not idx then return end

          local commit = commits[idx]
          local label = branch .. '  ' .. commit_display(commit)
          cb(commit.hash, commit.short, label)
        end)
      end)
    end)
  end)
end

-- 进入任意两个 ref 的比较模式：from_rev..to_rev
---@param state table
---@param from_rev string
---@param to_rev string
---@param short string
---@param label string
---@param on_done fun()
---@param on_error? fun(message:string)
function M.start_refs(state, from_rev, to_rev, short, label, on_done, on_error)
  local request, root = begin_request(state)
  Git.diff_names(root, from_rev, to_rev, function(files, err)
    if not is_current(state, request, root) then return end
    if not files then
      local message = 'Compare failed: ' .. (err or 'git diff error')
      vim.notify('[vv-git] ' .. message, vim.log.levels.ERROR)
      if on_error then on_error(message) end
      return
    end

    state.compare = {
      from_rev = from_rev,
      to_rev   = to_rev,
      short    = short,
      label    = label,
      files    = files,
    }
    on_done()
  end)
end

-- 进入"与 HEAD 比较"模式：from_rev..HEAD
---@param state table
---@param from_rev string
---@param short string
---@param label string
---@param on_done fun()
function M.start(state, from_rev, short, label, on_done)
  M.start_refs(state, from_rev, 'HEAD', short, label, on_done)
end

-- git empty-tree hash（无父 commit 时用作 from_rev）
local EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

-- 进入"查看 commit 本身"模式：commit^..commit（初始 commit 用 empty-tree）
---@param state table
---@param hash string
---@param short string
---@param label string
---@param on_done fun()
---@param on_error? fun(message:string)
function M.start_commit(state, hash, short, label, on_done, on_error)
  local request, root = begin_request(state)
  local function apply(from_rev, files)
    if not is_current(state, request, root) then return end
    state.compare = {
      from_rev = from_rev,
      to_rev   = hash,
      short    = short,
      label    = label,
      files    = files,
    }
    on_done()
  end

  Git.diff_names(root, hash .. '^', hash, function(files, err)
    if not is_current(state, request, root) then return end
    if files then
      apply(hash .. '^', files)
      return
    end
    -- 初始 commit 没有父节点，改用 empty-tree
    Git.diff_names(root, EMPTY_TREE, hash, function(files2, err2)
      if not is_current(state, request, root) then return end
      if not files2 then
        local message = 'Show commit failed: ' .. (err2 or err or 'git diff error')
        vim.notify('[vv-git] ' .. message, vim.log.levels.ERROR)
        if on_error then on_error(message) end
        return
      end
      apply(EMPTY_TREE, files2)
    end)
  end)
end

-- 退出比较模式
---@param state table
function M.stop(state)
  state._compare_req_id = (state._compare_req_id or 0) + 1
  state.compare = nil
end

return M
