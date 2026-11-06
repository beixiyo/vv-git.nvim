-- 测试专用真实线程门闩：仅等待隔离 fixture，超时失败而不是挂死线程池
return function(input, index)
  local gate = input.test_gate
  if gate then
    local file = assert(io.open(gate .. '.started', 'w'))
    file:write('started'); file:close()
    local deadline = vim.uv.hrtime() + 5e9
    while not vim.uv.fs_stat(gate) do
      assert(vim.uv.hrtime() < deadline, '测试门闩未释放')
      vim.uv.sleep(2)
    end
  end
  if input.test_error then error('测试计算失败') end
  local compute = require('vv-git.inline_diff.compute')
  local started = vim.uv.hrtime()
  local result = compute(input, index)
  if input.test_timing then result.test_compute_ms = (vim.uv.hrtime() - started) / 1e6 end
  if gate then
    local file = assert(io.open(gate .. '.finished', 'w'))
    file:write('finished'); file:close()
  end
  return result
end
