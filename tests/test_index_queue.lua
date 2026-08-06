-- Git index writer queue：同仓库串行、快速入队不争锁、不同仓库互不阻塞

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local IndexQueue = require('vv-git.index_queue')

local starts = {}
local callbacks = {}
local done_a

IndexQueue.enqueue('/repo-a', function(done)
  starts[#starts + 1] = 'a1'
  done_a = done
end, function(ok, _, idle)
  callbacks[#callbacks + 1] = { 'a1', ok, idle }
end)

IndexQueue.enqueue('/repo-a', function(done)
  starts[#starts + 1] = 'a2'
  done(true)
end, function(ok, _, idle)
  callbacks[#callbacks + 1] = { 'a2', ok, idle }
end)

IndexQueue.enqueue('/repo-b', function(done)
  starts[#starts + 1] = 'b1'
  done(true)
end, function(ok, _, idle)
  callbacks[#callbacks + 1] = { 'b1', ok, idle }
end)

assert(vim.deep_equal(starts, { 'a1', 'b1' }), 'same repo waits while another repo may start')
done_a(true)
assert(vim.deep_equal(starts, { 'a1', 'b1', 'a2' }), 'same repo starts in FIFO order')
assert(callbacks[2][1] == 'a1' and callbacks[2][3] == false,
  'non-final same-repo callback reports a non-idle queue')
assert(callbacks[3][1] == 'a2' and callbacks[3][3] == true,
  'final same-repo callback reports an idle queue')

local recovered = {}
IndexQueue.enqueue('/repo-c', function()
  error('start exploded')
end, function(ok, err)
  recovered[#recovered + 1] = not ok and err:find('start exploded', 1, true) ~= nil
end)
IndexQueue.enqueue('/repo-c', function(done)
  done(true)
  done(false, 'duplicate completion')
end, function(ok)
  recovered[#recovered + 1] = ok
end)
assert(vim.deep_equal(recovered, { true, true }),
  'a thrown starter and duplicate completion cannot wedge or double-finish the queue')

local Git = require('vv-git.git')
local repo = vim.fn.tempname()
vim.fn.mkdir(repo, 'p')
vim.fn.system({ 'git', '-C', repo, 'init', '-q' })

for _, path in ipairs({ 'a.txt', 'b.txt', 'c.txt' }) do
  vim.fn.writefile({ path }, repo .. '/' .. path)
end

local completed = {}
for _, path in ipairs({ 'a.txt', 'b.txt', 'c.txt' }) do
  Git.stage(repo, { path }, function(ok, err, idle)
    assert(ok, err or ('rapid stage failed for ' .. path))
    completed[#completed + 1] = { path, idle }
  end)
end

assert(vim.wait(3000, function() return #completed == 3 end), 'rapid stage queue completes')
assert(completed[1][1] == 'a.txt' and completed[1][2] == false, 'first stage remains queued')
assert(completed[2][1] == 'b.txt' and completed[2][2] == false, 'second stage remains queued')
assert(completed[3][1] == 'c.txt' and completed[3][2] == true, 'last stage drains queue')

local status = vim.fn.systemlist({ 'git', '-C', repo, 'status', '--short' })
table.sort(status)
assert(vim.deep_equal(status, { 'A  a.txt', 'A  b.txt', 'A  c.txt' }),
  'rapid stage writes every captured file without index.lock loss')

vim.fn.delete(repo, 'rf')
print('vv-git index writer queue: PASS')
