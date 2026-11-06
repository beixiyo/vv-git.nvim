-- 默认 chunk 映射只属于 vv-git scratch；真实文件上的现有映射必须原样保留
local T, child = dofile('tests/helpers.lua').new_set()

T['真实 buffer 的局部 hunk 映射在重复安装和释放前后身份不变'] = function()
  child.lua_func(function()
    local api = vim.api
    local b = api.nvim_get_current_buf()
    local next_hunk, prev_hunk = function() end, function() end
    vim.keymap.set('n', ']c', next_hunk, {buffer=b})
    vim.keymap.set('n', '[c', prev_hunk, {buffer=b})
    local k = require('vv-git.right.keymaps').new({callbacks={
      close=function() end, goto_file=function() end, yank_abs_path=function() end,
      toggle_stage=function() end, next_file=function() end, prev_file=function() end,
    },next_file_key=false,prev_file_key=false,revision_mappings={}})
    local function check()
      assert(vim.fn.maparg(']c','n',false,true).callback == next_hunk, '不得覆盖或删除原 ]c')
      assert(vim.fn.maparg('[c','n',false,true).callback == prev_hunk, '不得覆盖或删除原 [c')
    end
    k.install(b); check(); k.install(b); check(); k.remove(b); check()
  end)
end

T['无局部映射的真实 buffer 保留全局映射与原生命令'] = function()
  child.lua_func(function()
    local api = vim.api
    local b = api.nvim_get_current_buf()
    local hits = 0
    local global = function() hits = hits + 1 end
    vim.keymap.set('n', ']c', global)
    local k = require('vv-git.right.keymaps').new({callbacks={
      close=function() end, goto_file=function() end, yank_abs_path=function() end,
      toggle_stage=function() end, next_file=function() end, prev_file=function() end,
    },next_file_key=false,prev_file_key=false,revision_mappings={}})
    local function check()
      local map = vim.fn.maparg(']c','n',false,true)
      assert(map.buffer == 0 and map.callback == global, '不得遮蔽全局 ]c')
      assert(vim.tbl_isempty(vim.fn.maparg('[c','n',false,true)), '不得遮蔽原生 [c')
    end
    k.install(b); check()
    api.nvim_feedkeys(']c', 'xt', false)
    assert(hits == 1, '全局映射必须仍可执行')
    local win = api.nvim_get_current_win()
    api.nvim_buf_set_lines(b,0,-1,false,{'one','two','three'})
    vim.cmd('diffthis'); vim.cmd('vnew')
    api.nvim_buf_set_lines(0,0,-1,false,{'one','changed','three'})
    vim.cmd('diffthis'); vim.cmd('diffupdate'); api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win,{3,0}); api.nvim_feedkeys('[c','xt',false)
    assert(api.nvim_win_get_cursor(win)[1] == 2, '原生 [c 必须仍可执行')
    k.remove(b); check()
  end)
end

T['scratch diff 仍绑定并执行原生 chunk 导航'] = function()
  child.lua_func(function()
    local api=vim.api
    local b, win=api.nvim_get_current_buf(), api.nvim_get_current_win()
    vim.b[b].vv_git_scratch = true
    api.nvim_buf_set_lines(b,0,-1,false,{'one','two','three'})
    vim.cmd('diffthis'); vim.cmd('vnew')
    api.nvim_buf_set_lines(0,0,-1,false,{'one','changed','three'})
    vim.cmd('diffthis'); vim.cmd('diffupdate'); api.nvim_set_current_win(win)
    local k = require('vv-git.right.keymaps').new({callbacks={
      close=function() end, goto_file=function() end, yank_abs_path=function() end,
      toggle_stage=function() end, next_file=function() end, prev_file=function() end,
    },next_file_key=false,prev_file_key=false,revision_mappings={}})
    k.install(b)
    assert(vim.fn.maparg(']c','n',false,true).desc == 'vv-git: next_chunk', 'scratch 必须绑定 chunk 动作')
    api.nvim_win_set_cursor(win,{1,0}); api.nvim_feedkeys(']c','xt',false)
    assert(api.nvim_win_get_cursor(win)[1] == 2, 'scratch 必须执行 diff 跳转')
    k.remove(b)
    assert(vim.tbl_isempty(vim.fn.maparg(']c','n',false,true)), 'scratch 释放时删除自身绑定')
  end)
end

T['显式文件导航键与默认 chunk 键冲突时仍执行文件导航'] = function()
  child.lua_func(function()
    local b, hits=vim.api.nvim_get_current_buf(), 0
    local k = require('vv-git.right.keymaps').new({callbacks={
      close=function() end, goto_file=function() end, yank_abs_path=function() end,
      toggle_stage=function() end, next_file=function() hits=hits+1 end, prev_file=function() end,
    },next_file_key=']c',prev_file_key=false,revision_mappings={}})
    k.install(b); vim.api.nvim_feedkeys(']c','xt',false)
    assert(hits == 1, '显式配置动作不得与默认 chunk 一起被过滤')
    k.remove(b)
  end)
end

T['快照提升真实文件后多窗共享映射且关闭不误删'] = function()
  child.lua_func(function()
    local api, root=vim.api, vim.env.VV_TEST_TMP
    vim.o.columns, vim.o.lines=220,60
    vim.fn.writefile({'a','b','c'},root..'/promote.txt')
    require('vv-git').setup({auto_refresh=false,preview=false,worktree_preview='snapshot',snapshot_promote_ms=false})
    require('vv-git.git').show=function(_,_,_,cb) cb({'a','old','c'}) end
    local next_hunk,prev_hunk=function() end,function() end
    api.nvim_create_autocmd('BufReadPost',{pattern='*/promote.txt',callback=function(ev)
      vim.keymap.set('n',']c',next_hunk,{buffer=ev.buf})
      vim.keymap.set('n','[c',prev_hunk,{buffer=ev.buf})
    end})
    local main=api.nvim_get_current_win();vim.cmd('leftabove vsplit')
    local state={git_root=root,tabpage=api.nvim_get_current_tabpage(),panel={win=api.nvim_get_current_win(),main_win=main}}
    local view=require('vv-git.right.view')
    view.show(state,{relpath='promote.txt',xy=' M'},'unstaged',false,root)
    assert(state.view and state.view.b_snapshot, '必须首先挂载快照')
    assert(view.promote(state), '必须提升为真实 buffer')
    local b=state.view.b_buf
    local function check()
      api.nvim_buf_call(b,function()
        assert(vim.fn.maparg(']c','n',false,true).callback == next_hunk, '真实文件 ]c 不得改变')
        assert(vim.fn.maparg('[c','n',false,true).callback == prev_hunk, '真实文件 [c 不得改变')
      end)
    end
    check()
    api.nvim_set_current_win(state.panel.win);vim.cmd('vsplit');api.nvim_win_set_buf(0,b)
    assert(not vim.wo.diff, '另一个共享窗口应为普通窗口')
    check();view.close(state);check()
  end)
end
return T
