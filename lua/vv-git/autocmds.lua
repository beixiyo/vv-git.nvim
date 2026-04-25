-- 生命周期 autocmd 注册：
--   BufWritePost                 仓内文件保存 → 刷新左栏
--   VimResized                   终端尺寸变化 → 重排 panel / a_win
--   TabClosed                    专属 tab 被关掉 → 拆 diff 视图 + 清 state（统一清理入口）
--   WinClosed                    panel / diff 窗口被关 → 同步 state 字段并检查不变式
--   BufWinEnter                  a_win/b_win 的 buffer 被切走（如 bufferline）→ 拆 diff 视图

local State = require('vv-git.state')
local RightView = require('vv-git.right.view')
local Guard = require('vv-git.guard')

local M = {}

---@param handlers { on_refresh:fun(), on_apply_layout:fun(), on_ensure_invariant:fun() }
function M.setup(handlers)
  local aug = vim.api.nvim_create_augroup('VVGit', { clear = true })

  vim.api.nvim_create_autocmd('BufWritePost', {
    group = aug,
    callback = State.guarded(function(state, args)
      if not state.git_root then return end
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name == '' then return end
      name = vim.fs.normalize(name)
      if name:sub(1, #state.git_root) ~= state.git_root then return end
      if state._refresh_scheduled then return end
      state._refresh_scheduled = true
      vim.schedule(function()
        state._refresh_scheduled = false
        handlers.on_refresh()
      end)
    end),
  })

  -- 仅当 vv-git tab 是当前 tab 时才重排
  vim.api.nvim_create_autocmd('VimResized', {
    group = aug,
    callback = State.guarded(function(state)
      if state.tabpage and vim.api.nvim_get_current_tabpage() == state.tabpage then
        handlers.on_apply_layout()
      end
    end),
  })

  -- 任何方式关了 vv-git tab 都走这里：统一清 state + b_buf 上的 buf-local 快捷键
  -- 注：TabClosed 的 args.file 是 1-based 序号，state.tabpage 是 id（handle），两者不能直接比。
  --    改用"我们的 tabpage 是否仍 valid"来判断——tabpage 被关后 handle 会失效
  vim.api.nvim_create_autocmd('TabClosed', {
    group = aug,
    callback = State.guarded(function(state)
      if state.tabpage and not vim.api.nvim_tabpage_is_valid(state.tabpage) then
        pcall(RightView.close, state)
        -- panel_buf 是 bufhidden=hide：tab 关闭只会隐藏 buf，不会真删。
        -- 每次 open 新建一个 buf → 不显式 wipe 会 N 次 open/close 后残留 N 个
        -- vv-git://panel/X 幽灵 buffer（bufferline / :ls 可见）。
        local pb = state.panel and state.panel.buf
        if pb and vim.api.nvim_buf_is_valid(pb) then
          pcall(vim.api.nvim_buf_delete, pb, { force = true })
        end
        -- 还原全局 nvim_open_win；此后第三方浮窗在任何 tab 都不再经过我们
        pcall(Guard.uninstall)
        State.clear()
      end
    end),
  })

  -- panel / a_win / b_win 被外部关闭（:q、<C-w>q、<leader>b 隐藏 panel 等）→
  -- 同步 state 字段，检查不变式；若 tab 已无用途则调度回收
  vim.api.nvim_create_autocmd('WinClosed', {
    group = aug,
    callback = State.guarded(function(state, args)
      local closed_win = tonumber(args.match)
      if not closed_win then return nil end

      local dirty = false
      if state.panel and state.panel.win == closed_win then
        state.panel.win = nil
        dirty = true
      end
      local view = state.view
      if view and (view.a_win == closed_win or view.b_win == closed_win) then
        pcall(RightView.close, state)
        dirty = true
      end
      if dirty then handlers.on_ensure_invariant() end
      return nil
    end),
  })

  -- 专属 tab 屏蔽了外部窗口，但 bufferline 在本 tab 仍可切换 b_win 的 buffer
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = aug,
    callback = State.guarded(function(state, args)
      local view = state.view
      if not view then return end
      if state.tabpage ~= vim.api.nvim_get_current_tabpage() then return end
      local win = vim.api.nvim_get_current_win()
      local function stale(w, expected_buf)
        return w and vim.api.nvim_win_is_valid(w) and w == win and expected_buf ~= args.buf
      end
      if stale(view.b_win, view.b_buf) or stale(view.a_win, view.a_buf) then
        RightView.close(state)
        -- view 没了，若 panel 也藏着（<leader>b）则 tab 无用途 → 回收
        handlers.on_ensure_invariant()
      end
    end),
  })
end

return M
