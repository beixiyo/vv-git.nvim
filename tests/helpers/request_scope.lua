-- request-scope 测试的最小运行时与 fixture 工厂

local H = {}

H.noop = function() end

function H.assert_eq(actual, expected, message)
  assert(actual == expected, message .. ': 期望 ' .. vim.inspect(expected) .. ', 实际 ' .. vim.inspect(actual))
end

function H.create_file_compare_fixture()
  vim.cmd('only')
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(source_buf, '/repo/file.lua')
  vim.bo[source_buf].filetype = 'lua'
  vim.api.nvim_win_set_buf(0, source_buf)
  return source_buf
end

return H
