-- Git revision 查询：show、分支、日志与 revision diff 文件列表

local M = {}

---@param root string
---@param rev string
---@param relpath string
---@param cb fun(lines: string[]?, err?: string)
function M.show(root, rev, relpath, cb)
  vim.system(
    { 'git', '-C', root, 'show', rev .. ':' .. relpath },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git show failed'); return end
      local text = (r.stdout or ''):gsub('\r\n', '\n')
      if text:sub(-1) == '\n' then text = text:sub(1, -2) end
      cb(vim.split(text, '\n', { plain = true }))
    end)
  )
end

---@param root string
---@param cb fun(branches: string[]?, err?: string)
---@param opts? { local_only?:boolean }
function M.branches(root, cb, opts)
  local args = { 'git', '-C', root, 'branch' }
  if not (opts and opts.local_only) then args[#args + 1] = '-a' end
  args[#args + 1] = '--format=%(refname:short)'
  vim.system(
    args,
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git branch failed'); return end
      local result = {}
      for _, l in ipairs(vim.split(vim.trim(r.stdout or ''), '\n', { plain = true })) do
        l = vim.trim(l)
        if l ~= '' then result[#result + 1] = l end
      end
      cb(result)
    end)
  )
end

---@param root string
---@param ref string
---@param cb fun(info: {hash:string, branch:string, subject:string}?)
function M.conflict_info(root, ref, cb)
  vim.system(
    { 'git', '-C', root, 'log', '-1', '--format=%h%x00%D%x00%s', ref },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil); return end
      local parts = vim.split(vim.trim(r.stdout or ''), '\0', { plain = true })
      local hash     = parts[1] or ''
      local refnames = parts[2] or ''
      local subject  = parts[3] or ''
      local branch = refnames:match('HEAD %-> ([^,]+)')
                  or refnames:match('^([^,%(]+)')
                  or ''
      cb({ hash = vim.trim(hash), branch = vim.trim(branch), subject = vim.trim(subject) })
    end)
  )
end

---@param root string
---@param ref string
---@param n integer
---@param cb fun(commits: {hash:string, short:string, subject:string}[]?, err?: string)
function M.log(root, ref, n, cb)
  vim.system(
    { 'git', '-C', root, 'log', ref, '--pretty=format:%H\x01%h\x01%s', '-' .. (n or 50) },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git log failed'); return end
      local result = {}
      for _, line in ipairs(vim.split(vim.trim(r.stdout or ''), '\n', { plain = true })) do
        local hash, short, subject = line:match('^([^\x01]+)\x01([^\x01]+)\x01(.*)$')
        if hash then
          result[#result + 1] = { hash = vim.trim(hash), short = vim.trim(short), subject = subject or '' }
        end
      end
      cb(result)
    end)
  )
end

---@param root string
---@param from_ref string
---@param to_ref string
---@param cb fun(files: {status:string, path:string, old_path?:string}[]?, err?: string)
function M.diff_names(root, from_ref, to_ref, cb)
  vim.system(
    { 'git', '-C', root, 'diff', '--name-status', '-z', from_ref .. '..' .. to_ref },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git diff failed'); return end
      local result = {}
      local fields = vim.split(r.stdout or '', '\0', { plain = true })
      local i = 1
      while i <= #fields do
        local status_raw = fields[i]
        if status_raw == '' then
          i = i + 1
        else
          local st = status_raw:sub(1, 1)
          if st == 'R' or st == 'C' then
            local old_path = fields[i + 1]
            local new_path = fields[i + 2]
            if new_path and new_path ~= '' then
              result[#result + 1] = { status = st, path = new_path, old_path = old_path }
            end
            i = i + 3
          else
            local path = fields[i + 1]
            if path and path ~= '' then result[#result + 1] = { status = st, path = path } end
            i = i + 2
          end
        end
      end
      cb(result)
    end)
  )
end

return M
