local T, child = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua').new_set()

-- 失败信号来自可见契约：行色、字节区间、删除行位置/色块与折叠，不复制 diff 算法生成期望
local cases = {
  { name = '新增行', a = { 'keep', 'tail' }, b = { 'keep', 'new', 'tail' }, first = 2,
    lines = { { 1, 'VVGitDiffAdd' } }, words = {}, deleted = {} },
  { name = '头部删除', a = { 'gone', 'keep', 'tail' }, b = { 'keep', 'tail' }, first = 1,
    lines = {}, words = {}, deleted = { { 0, true, 'gone', 'VVGitDiffAddAsDelete' } } },
  { name = '中间删除', a = { 'keep', 'gone', 'tail' }, b = { 'keep', 'tail' }, first = 1,
    lines = {}, words = {}, deleted = { { 0, false, 'gone', 'VVGitDiffAddAsDelete' } } },
  { name = '尾部删除保留无尾换行策略', a = { 'keep', 'tail', 'gone' }, b = { 'keep', 'tail' }, first = 2,
    lines = { { 1, 'VVGitDiffChange' } }, words = {},
    deleted = { { 1, false, 'gone', 'VVGitDiffAddAsDelete' }, { 1, true, 'tail', 'VVGitDiffAddAsDelete' } } },
  { name = '修改字符', a = { 'prefix red suffix', 'tail' }, b = { 'prefix blue suffix', 'tail' }, first = 1,
    lines = { { 0, 'VVGitDiffChange' } }, words = { { 0, 7, 11 } },
    deleted = { { 0, true, 'prefix red suffix', 'VVGitDiffChangeDelete' } },
    chunks = { { 'prefix ', 'VVGitDiffChangeDelete' }, { 'red', 'VVGitDiffTextDelete' } } },
  { name = '行尾字符插入', a = { 'hello', 'tail' }, b = { 'hello!', 'tail' }, first = 1,
    lines = { { 0, 'VVGitDiffChange' } }, words = { { 0, 5, 6 } },
    deleted = { { 0, true, 'hello', 'VVGitDiffAddAsDelete' } } },
  { name = 'Unicode 保持既有字节区间', a = { '前a', 'tail' }, b = { '前b', 'tail' }, first = 1,
    lines = { { 0, 'VVGitDiffChange' } }, words = { { 0, 3, 4 } },
    deleted = { { 0, true, '前a', 'VVGitDiffChangeDelete' } } },
  { name = '不等长修改保留 linematch 拆分', a = { 'keep', 'AAA', 'BBB', 'tail' }, b = { 'keep', 'ZZZ', 'tail' }, first = 1,
    lines = { { 1, 'VVGitDiffChange' } }, words = { { 1, 0, 3 } },
    deleted = { { 0, false, 'AAA', 'VVGitDiffAddAsDelete' }, { 1, true, 'BBB', 'VVGitDiffTextDelete' } } },
  { name = '空内容无导航或装饰', a = {}, b = { '' }, lines = {}, words = {}, deleted = {} },
}

for _, case in ipairs(cases) do
  T[case.name] = function()
    child.lua_func(function(c)
      local api = vim.api
      local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
      api.nvim_buf_set_lines(buf, 0, -1, false, c.b)
      local result
      local cleanup = require('vv-git.inline_diff').apply_async(buf, c.a, 100, {
        b_win = win, on_initial_ready = function(value) result = value end,
      })
      assert(vim.wait(3000, function() return result ~= nil end, 5), '真实 worker 必须完成计算')
      assert(result.first_b_line == c.first, '首 hunk 行号必须保持：' .. vim.inspect(result))
      local marks = api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace('vv-git-inline-diff'),
        0, -1, { details = true })
      local lines, words, deleted, chunks = {}, {}, {}, nil
      for _, mark in ipairs(marks) do
        local row, col, detail = mark[2], mark[3], mark[4]
        if detail.line_hl_group then lines[#lines + 1] = { row, detail.line_hl_group } end
        if detail.hl_group == 'VVGitDiffText' then words[#words + 1] = { row, col, detail.end_col } end
        for _, line in ipairs(detail.virt_lines or {}) do
          chunks = chunks or line
          local text = ''
          for _, chunk in ipairs(line) do text = text .. chunk[1] end
          assert(#text == 200, '删除行必须保留200字节 padding')
          deleted[#deleted + 1] = { row, detail.virt_lines_above, text:gsub(' +$', ''), line[1][2] }
        end
      end
      assert(vim.deep_equal(lines, c.lines), '行高亮变化：' .. vim.inspect(lines))
      assert(vim.deep_equal(words, c.words), '字符区间变化：' .. vim.inspect(words))
      assert(vim.deep_equal(deleted, c.deleted), '删除虚拟行变化：' .. vim.inspect(deleted))
      if c.chunks then
        for i, expected in ipairs(c.chunks) do
          assert(vim.deep_equal(chunks[i], expected), '删除侧浅/深红字符分块必须保持')
        end
      end
      cleanup()
    end, case)
  end
end

T['超出 linematch 配对范围的不等长 hunk 无字符高亮'] = function()
  child.lua([[
    local a = { 'keep' }
    for i = 1, 61 do a[#a + 1] = 'old ' .. i end
    a[#a + 1] = 'tail'
    local b = { 'keep', 'new', 'tail' }
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, b)
    local result
    local cleanup = require('vv-git.inline_diff').apply_async(buf, a, 100, {
      on_initial_ready = function(value) result = value end,
    })
    assert(vim.wait(3000, function() return result ~= nil end, 5), '计算未完成')
    local deleted = 0
    for _, mark in ipairs(result.marks) do
      assert(not mark[3].hl_group, '不等长 hunk 不得按行强配 word diff')
      deleted = deleted + #(mark[3].virt_lines or {})
    end
    assert(deleted == 61 and result.first_b_line == 2, '必须完整保留删除行和首变更位置')
    cleanup()
  ]])
end

T['上下六行上下文的折叠范围及实际 manual fold'] = function()
  child.lua([[
    local api = vim.api
    local a, b = {}, {}
    for i = 1, 80 do a[i], b[i] = 'line ' .. i, 'line ' .. i end
    b[40] = 'changed'
    local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    api.nvim_buf_set_lines(buf, 0, -1, false, b)
    local result
    local cleanup = require('vv-git.inline_diff').apply_async(buf, a, 100, {
      b_win = win, on_initial_ready = function(value) result = value end,
    })
    assert(vim.wait(3000, function() return result ~= nil end, 5), '折叠计算未完成')
    assert(vim.deep_equal(result.folds, { { 1, 33 }, { 47, 80 } }), '折叠必须保留上下六行')
    assert(vim.wo.foldmethod == 'manual' and vim.fn.foldclosed(70) == 47, '必须应用真实 manual fold')
    cleanup()
  ]])
end

return T
