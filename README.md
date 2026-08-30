<div align="center">
  <h1>vv-git.nvim</h1>
  <p>English | <a href="./README.zh-CN.md">中文</a></p>
  <img src="https://github.com/beixiyo/vv-git.nvim/releases/download/assets-2026-07-25/vv-git.png" alt="vv-git demo" width="900" />
  <img src="https://github.com/beixiyo/vv-git.nvim/releases/download/assets-2026-07-25/vv-git-conflict.png" alt="Conflict resolution" width="900" />
  <img src="https://github.com/beixiyo/vv-git.nvim/releases/download/assets-2026-07-25/vv-git-help.png" alt="Keymap help" width="900" />
  <p>Want my Neovim configuration? See <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <em>A VS Code-style two-column Git diff view with dedicated tab isolation and automatic folding of unchanged code</em>
  <p>
    <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
    <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  </p>
</div>

---

## Requirements

- [Git](https://github.com/git/git) — required for status, diff, staging, commits, branches, remotes, and worktrees
- [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) — required for shared Git parsing, filesystem, and UI utilities

## Installation

```lua
{
  'beixiyo/vv-git.nvim',
  dependencies = { 'beixiyo/vv-utils.nvim' },
  cmd = {
    'VVGit', 'VVGitClose', 'VVGitToggle', 'VVGitTogglePanel', 'VVGitRefresh',
    'VVGitCompare', 'VVGitCompareRef', 'VVGitCompareRefs', 'VVGitCompareFile',
    'VVGitCompareStop', 'VVGitCommitShow', 'VVGitWorktree', 'VVGitPublish',
    'VVGitShow', 'VVGitSubrepoDepth', 'VVGitLoad',
  },
  keys = { '<leader>b' },
  ---@type VVGitConfig
  opts = {
    width = 30,                        -- Left panel width
    parent_repository = 'prompt',      -- Prompt when cwd belongs to a repository above it (always/never)
    single_col_threshold = 120,        -- Fall back to one column + inline diff below this width
    keymap_toggle_panel = '<leader>b', -- Global mapping for toggling the left panel (false to disable)
    keymap_select = '<Tab>',           -- Toggle selection for the current file (multi-select)
    keymap_next_file = '<C-j>',        -- Open the next file from a diff buffer (false disables)
    keymap_prev_file = '<C-k>',        -- Open the previous file from a diff buffer (false disables)
    fold_unchanged = true,             -- Fold unchanged code
    fold_staged = false,               -- Fold only the Staged Changes section when opening the panel
    diff_fill = ' ',                   -- Fill character for diff filler lines (Vim defaults to '-')
    preview = true,                    -- Refresh the right-side diff when moving over a file row
    directory_preview = true,          -- Show change counts and status breakdown when moving over a directory row
    inline_diff_max_lines = 10000,     -- Maximum line count for inline diff in single-column mode
    diff_ratio = { 4, 6 },             -- Width ratio of a_win:b_win in two-column mode (defaults to 50:50)
    conflict_result_ratio = 0.5,       -- Height ratio of the bottom result/worktree window in conflict view
  },
}
```

## Configuration

| Option | Type | Default | Description |
|------|------|--------|------|
| `width` | `integer` | `30` | Left-panel width; manual changes persist across sessions |
| `state` | `VVStateHandle?` | `nil` | Optional state container; defaults to `vv-git/panel` |
| `parent_repository` | `'prompt' \| 'always' \| 'never'` | `'prompt'` | How implicit opens handle a Git repository above the cwd/explorer directory; `prompt` remembers the choice per directory for the current Neovim session |
| `single_col_threshold` | `integer` | `120` | Use a single-column diff below this window width |
| `keymap_toggle_panel` | `string \| false` | `'<leader>b'` | Toggle the left panel globally; `false` disables it |
| `fold_unchanged` | `boolean` | `true` | Fold unchanged code by default |
| `fold_staged` | `boolean` | `false` | Fold the parent repository's Staged Changes on open |
| `diff_fill` | `string` | `' '` | Diff filler character |
| `preview` | `boolean` | `true` | Refresh the diff while moving in the left panel |
| `directory_preview` | `boolean` | `true` | Preview directory change statistics; requires `preview` |
| `auto_refresh` | `boolean` | `true` | Refresh Git status on BufEnter / FocusGained |
| `preview_debounce_ms` | `integer` | `150` | Preview debounce in milliseconds; `0` disables it |
| `inline_diff_max_lines` | `integer` | `10000` | Maximum line count for single-column inline diff |
| `right_click` | `string \| false` | `'toggle_stage'` | Right-click action; `false` disables it |
| `diff_ratio` | `number[]` | `{ 5, 5 }` | Width ratio of a_win:b_win |
| `conflict_result_ratio` | `number` | `0.5` | Conflict result-window height ratio (`0.1`–`0.9`) |
| `diff_nowrap` | `boolean` | `false` | Force wrapping off in diff windows |
| `highlights` | `table` | `nil` | Override any `VVGit*` highlight group |
| `before_open` | `fun(): fun()?` | `nil` | Runs before opening and may return a close-time restore function |
| `keymap_select` | `string` | `'<Tab>'` | Toggle selection for the current row (multi-select); directory nodes are ignored |
| `keymap_next_file` | `string \| false` | `'<C-j>'` | Open the next file from a diff buffer |
| `keymap_prev_file` | `string \| false` | `'<C-k>'` | Open the previous file from a diff buffer |
| `select_move_down` | `boolean` | `true` | Move down after toggling selection |
| `mappings` | `table<string, fun(state)>` | `{}` | Add or override left-panel mappings |
| `revision_mappings` | `table<string, fun(context)>` | `{}` | Add or override mappings in revision/index scratch buffers; context contains `bufnr`, `winid`, and `source_path` |
| `binary.intercept` | `boolean` | `true` | Intercept binary files and open them with the system application |
| `binary.extensions` | `table<string, boolean>` | Built-in list | Binary extension overrides; merged with defaults |
| `subrepo.depth` | `integer` | `0` | Nested-repository scan depth; `0` disables scanning |
| `subrepo.respect_gitignore` | `boolean` | `false` | Whether discovery skips directories ignored by the parent repository's `.gitignore` |
| `subrepo.prune` | `string[]` | Built-in list | Directory names excluded from scans; replaces the default list |
| `subrepo.scan_worktrees` | `boolean` | `false` | Treat linked worktrees as nested repositories |
| `worktree.path` | `fun(root, branch): string` | `<root>/.worktrees/<branch-short>` | Path policy for new worktrees |

## Configuration Examples

```lua
opts = {
  subrepo = {
    depth = 1,                  -- Scan one level below cwd for nested repositories
    respect_gitignore = false,  -- Default; required to find ignored projects under a HOME repository
    -- prune is an array with replacement semantics. Providing it replaces the defaults
    -- (which include node_modules, .cache, .local, .cargo, and other caches).
    -- To extend the defaults, list the default entries as well.
    prune = { 'node_modules', '.cache', '.local', '.cargo', 'my_huge_dir' },
  },
  binary = {
    extensions = { png = false, jpg = false, jpeg = false },
  },
  highlights = {
    VVGitDiffAdd = { bg = '#1a3a1a' },
    VVGitDiffAddAsDelete = { bg = '#4a1a1a' },
  },
  worktree = {
    path = function(root, branch)
      return vim.fs.joinpath(root, '.worktrees', branch)
    end,
  },
}
```

`subrepo.prune` uses replacement semantics; `binary.extensions` and `highlights` use merge semantics.

## Plugin Integration

- `vv-scrollbar.nvim`: adjusts scrollbars and Git markers in diff windows.
- `vv-statuscol.nvim`: hides duplicate Git tracks in diff/result windows.

## Keymaps

When `:VVGit` is opened from a cwd that is not inside a Git repository, the panel opens an initialization state. If the cwd only belongs to a repository above the workspace boundary, the default `parent_repository='prompt'` shows both `p` to open that parent and `i` to initialize the current directory. The cursor defaults to `i` when the parent ignores the directory and to `p` otherwise. Use either key or `<CR>` to continue into the normal repository view in the same tab. Choosing `p` is remembered per cwd for the current Neovim session, so reopening vv-git does not prompt again; restarting Neovim resets the choice. Explicit invalid `root`/`path` arguments are still rejected.

These mappings are active inside the left panel:

| Key | Description |
|------|------|
| `i` | Initialize the current cwd as a Git repository (non-repository or parent-repository choice screen) |
| `p` | Open a Git repository above the workspace boundary (choice screen only; remains push in a normal repository) |
| `gf` | Jump to the file |
| `Y` | Copy the absolute file path |
| `<Tab>` | Toggle selection for the current file (multi-select; directories are ignored; configurable with `keymap_select`) |
| `<Esc>` | Clear a non-empty selection; otherwise close the panel |
| `j` / `k` / `↓` / `↑` | Jump to the next/previous selectable item (`<C-n>`/`<C-p>` are aliases; arrow keys match `j`/`k`) |
| `<CR>` / `l` / `→` | Choice screen: run the selected action; file: open its diff; directory/**section heading**: expand or collapse it (`→` matches `l`) |
| `o` | Open with a system tool: files use the default application and directories use the file manager |
| `X` | Execute according to file type: resolve a runner, ask for confirmation, then run it in a bottom split terminal (file nodes only) |
| `h` / `←` | Collapse the current node; a child file collapses to its parent directory; on a **top-level file or section heading**, collapse the entire section (Staged / Changes / Merge Conflicts) and return to its heading (`←` matches `h`) |
| `zR` | Keep focus in the left panel while toggling all folds in the current right-side diff |
| `-` | Single selection: toggle stage/unstage; **multi-selection:** batch stage/unstage |
| `d` | Single selection—staged: unstage; unstaged: discard after confirmation; **multi-selection:** batch the corresponding single-selection behavior |
| `c` | Commit |
| `p` | Push |
| `P` | Pull |
| `u` | Publish the current branch: use `origin` when present, the only existing remote when unambiguous, select among multiple remotes, or ask only for an `origin` URL when none exists |
| `<C-e>` | Scroll the diff down |
| `<C-y>` | Scroll the diff up |
| `]c` / `[c` | Jump to and center the next/previous chunk in the right-side diff while remaining in the left panel |
| `gc` | Inspect a commit's own diff: select a branch, then a commit, and show the changes introduced by that commit (`commit^..commit`) |
| `gw` | Manage worktrees: create, switch, remove, and refresh them in a floating window (equivalent to `:VVGitWorktree`) |
| `H` | Compare with HEAD: select a branch, then a commit, and show the `commit..HEAD` difference |
| `g?` | Show help |

## Public Interfaces

### User Commands

| Category | Commands |
|----------|----------|
| Panel | `:VVGit`, `:VVGitClose`, `:VVGitToggle`, `:VVGitTogglePanel`, `:VVGitRefresh` |
| Pickers | `:VVGitCompare`, `:VVGitCommitShow`, `:VVGitWorktree` |
| Revisions | `:VVGitShow <ref>`, `:VVGitCompareRef <ref>`, `:VVGitCompareRefs <from> <to>`, `:VVGitCompareFile <ref>`, `:VVGitCompareStop` |
| Git operation | `:VVGitPublish` |
| Configuration / loading | `:VVGitSubrepoDepth [n]`, `:VVGitLoad` (lazy-load hook only) |

### Lua API

```lua
local git = require('vv-git')

git.setup(opts)
git.config()                         -- returns a configuration copy
git.open({ root?, path?, on_ready?, on_error?, on_close? })
git.close()
git.toggle()
git.toggle_panel()
git.refresh()
git.is_open()
git.get_context()

git.show_commit(ref, opts?)
git.compare_with_head(ref, opts?)
git.compare_refs(from_ref, to_ref, opts?)
git.compare_file(ref, opts?)
git.stop_compare()

git.get_subrepo_depth()
git.set_subrepo_depth(n)
git.get_node_path()
git.get_target_paths()
git.get_node_dir()
```

`open` and the panel revision APIs accept:

```lua
{
  root = '/path/to/repo',            -- repository or a directory inside it; defaults to cwd
  path = 'src/main.lua',             -- repository-relative or absolute path
  on_ready = function(context) end,  -- panel / revision data is ready
  on_error = function(message) end,
  on_close = function(context) end,  -- the entire vv-git tab has closed
  on_goto_file = function(context) end, -- optional: override gf; by default vv-git closes and edits the file
}
```

`get_context()` and callbacks return stable snapshots. When `on_goto_file` is provided, the caller owns file opening; `compare_file` also accepts `bufnr`.

Fields and methods whose names start with `_` are internal implementation details and are not part of the public API.

### External Event

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'VVGitStatusChanged',
  callback = function(args)
    local root = args.data.root
  end,
})
```

`User VVGitStatusChanged` is emitted after repository index refresh. vv-git also listens for `User VVExplorerRootChanged`:

```lua
vim.api.nvim_exec_autocmds('User', {
  pattern = 'VVExplorerRootChanged',
  data = { root = '/path/to/dir' },
})
```
