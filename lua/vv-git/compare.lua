-- compare.lua — 比较模式：选分支 → 选 commit → diff commit..HEAD
-- state.compare = { commit, short, label, files }
-- files: { status='M'|'A'|'D'|'R'|'C', path, old_path? }[]

local M = {}

local Git = require('vv-git.git')

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

  Git.branches(state.git_root, function(branches, err)
    if not branches or #branches == 0 then
      vim.notify('[vv-git] ' .. (err or 'No branches found'), vim.log.levels.WARN)
      return
    end

    vim.ui.select(branches, {
      prompt = 'Compare HEAD with commit from branch:',
    }, function(branch)
      if not branch then return end

      Git.log(state.git_root, branch, 50, function(commits, lerr)
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
          if not idx then return end
          local commit = commits[idx]
          local label = branch .. '  ' .. commit_display(commit)
          cb(commit.hash, commit.short, label)
        end)
      end)
    end)
  end)
end

-- 进入比较模式：加载 from_rev..HEAD 的文件列表，回调 on_done
---@param state table
---@param from_rev string
---@param short string
---@param label string
---@param on_done fun()
function M.start(state, from_rev, short, label, on_done)
  Git.diff_names(state.git_root, from_rev, 'HEAD', function(files, err)
    if not files then
      vim.notify('[vv-git] Compare failed: ' .. (err or 'git diff error'), vim.log.levels.ERROR)
      return
    end
    state.compare = {
      commit = from_rev,
      short = short,
      label = label,
      files = files,
    }
    on_done()
  end)
end

-- 退出比较模式
---@param state table
function M.stop(state)
  state.compare = nil
end

return M
