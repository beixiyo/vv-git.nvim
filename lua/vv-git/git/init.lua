-- vv-git Git API facade：保持 require('vv-git.git') 的稳定导出入口

local Operations = require('vv-git.git.operations')
local Revisions = require('vv-git.git.revisions')
local Conflicts = require('vv-git.git.conflicts')
local Repository = require('vv-git.git.repository')
local Worktree = require('vv-git.git.worktree')

local M = {}

for _, module in ipairs({ Operations, Revisions, Conflicts, Repository, Worktree }) do
  for name, value in pairs(module) do
    if name:sub(1, 1) ~= '_' then M[name] = value end
  end
end

M._parse_repo_info = Repository._parse_repo_info

return M
