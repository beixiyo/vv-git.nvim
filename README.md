<div align="center">
  <h1>vv-git.nvim</h1>
  <p>English | <a href="./README.zh-CN.md">中文</a></p>
  <img src="./docs/assets/vv-git.png" alt="vv-git demo" width="900" />
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
    single_col_threshold = 120,        -- Fall back to one column + inline diff below this width
    keymap_toggle_panel = '<leader>b', -- Global mapping for toggling the left panel (false to disable)
    keymap_select = '<Tab>',           -- Toggle selection for the current file (multi-select)
    fold_unchanged = true,             -- Fold unchanged code
    fold_staged = false,               -- Fold only the Staged Changes section when opening the panel
    diff_fill = ' ',                   -- Fill character for diff filler lines (Vim defaults to '-')
    preview = true,                    -- Refresh the right-side diff when moving over a file row
    inline_diff_max_lines = 10000,     -- Maximum line count for inline diff in single-column mode
    diff_ratio = { 4, 6 },             -- Width ratio of a_win:b_win in two-column mode (defaults to 50:50)
    conflict_result_ratio = 0.5,       -- Height ratio of the bottom result/worktree window in conflict view
  },
}
```

## Configuration

| Option | Type | Default | Description |
|------|------|--------|------|
| `width` | `integer` | `30` | Left panel width in characters |
| `single_col_threshold` | `integer` | `120` | Fall back to one column (b side only + inline diff) below this window width; use two columns at or above it; resize migrates automatically |
| `keymap_toggle_panel` | `string \| false` | `'<leader>b'` | Global mapping for toggling the left panel; `false` disables it |
| `fold_unchanged` | `boolean` | `true` | Whether unchanged code is folded by default (`foldmethod=diff` in dual mode; manual folds in single mode) |
| `fold_staged` | `boolean` | `false` | Automatically fold the parent repository's `Staged Changes` section to its heading only; nested repository blocks are unaffected |
| `diff_fill` | `string` | `' '` | Diff filler character, mapped to `diff:X` in `fillchars` |
| `preview` | `boolean` | `true` | Refresh the right-side diff as the cursor moves in the left panel, without requiring `<CR>` |
| `inline_diff_max_lines` | `integer` | `10000` | Maximum line count supported by `vim.diff` in single-column mode; larger files show text without diff highlighting |
| `right_click` | `string \| false` | `'toggle_stage'` | Action invoked by right-click, such as `'yank_abs_path'`; `false` disables it |
| `diff_ratio` | `integer[]` | None (50:50) | Width ratio between a_win (old version) and b_win (worktree) in two-column mode; `{4, 6}` makes the left side narrower; omitted means equal widths |
| `conflict_result_ratio` | `number` | `0.5` | Height ratio of the bottom result/worktree window in the three-pane conflict view, from `0.1` to `0.9` |
| `diff_nowrap` | `boolean` | `false` | Keep wrapping by default; when `true`, force wrapping off in diff views. Wrapping can visually misalign two-column views because the sides may have different row heights, a known upstream limitation ([neovim/neovim#29518](https://github.com/neovim/neovim/issues/29518), [diffview.nvim#198](https://github.com/sindrets/diffview.nvim/issues/198)) |
| `highlights` | `table` | None | Override any `VVGit*` highlight group on top of automatically computed values; overrides survive colorscheme changes (see “Custom Colors” below) |
| `keymap_select` | `string` | `'<Tab>'` | Toggle selection for the current row (multi-select); directory nodes are ignored |
| `select_move_down` | `boolean` | `true` | Move the cursor down one row after `<Tab>` toggles selection |
| `binary.intercept` | `boolean` | `true` | Intercept binary files: silently skip previews and open them with the system default application on `<CR>`/`gf`; `false` disables interception |
| `binary.extensions` | `table<string, boolean>` | See below | Extensions treated as binary, using lowercase keys; merged with `vim.tbl_deep_extend`, so only overridden keys are required |
| `subrepo.depth` | `integer` | `0` | Maximum directory depth for scanning nested repositories (independent Git repositories or submodules); `0` disables scanning. Temporarily change it with `:VVGitSubrepoDepth <n>` without persisting the value |
| `subrepo.respect_gitignore` | `boolean` | `false` | Whether discovery skips directories ignored by the parent repository's `.gitignore` |
| `subrepo.prune` | `string[]` | See below | Directory names not entered while discovering nested repositories. This uses replacement semantics: providing it replaces the entire default list instead of merging. Defaults include caches such as `node_modules`, `.cache`, `.local`, `.cargo`, `.rustup`, and `.bun`; `.git` is always skipped |
| `subrepo.scan_worktrees` | `boolean` | `false` | Whether linked worktrees are also scanned as nested repositories; defaults to `false` |

## vv-scrollbar Integration

When `vv-scrollbar.nvim` is also installed, the left reference window in a two-column diff automatically disables its scrollbar, while the right window keeps its marker track visible. For staged changes, the right window projects line-level changes from the index against HEAD as Git markers.

Single-column and conflict result windows retain their normal behavior and require no additional configuration.

When `vv-statuscol.nvim` is also installed, every diff/result window hides the status column's dual Git tracks to avoid duplicating scrollbar markers and diff coloring. This control is window-local, so staged/unstaged tracks remain visible when the same file is open in a normal editing window.

## Nested Repository Scanning

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
}
```

**Correct per-repository routing:** each block routes file diffs, stage/unstage/discard operations, and conflict acceptance to the file's **own repository**. Internally it uses `git -C <nested-repository-root>` with repository-relative paths, so repository states never leak into one another.

- **`c` commit / `p` push / `P` pull:** operate on the repository belonging to the node under the cursor
- **Ignored directories are scanned by default:** with the default `respect_gitignore=false`, directories ignored by `.gitignore` are still scanned; configure `respect_gitignore` to change this
- **Worktrees are not treated as nested repositories by default:** enable `scan_worktrees=true` when needed

## Worktree Switching

Press `gw` in the panel, or run `:VVGitWorktree`, to open a floating window listing every Git worktree for the current repository:

- The **current** worktree is marked and highlighted with `●`, and receives the initial cursor position
- Each row shows the branch name (`(detached <short hash>)` for detached HEAD or `(bare)` for a bare repository) and working directory path; invalid or locked worktrees end with `(prunable)` or `(locked)`
- Select with `<CR>` / `l` to **switch the panel to that worktree** and inspect its diff; close with `q` / `<Esc>`

Switching performs a clean context change: it points `state.git_root` at the selected worktree and runs `tcd` there, affecting only vv-git's dedicated tab and leaving the tab you came from untouched, then reloads. Subsequent diff, stage, unstage, commit, and push operations all target that worktree. This is a **read-only switcher**; it does not run `worktree add` or `worktree remove`, which should be managed with Git commands as needed.

> Worktrees and nested repositories are different concepts. Worktrees are multiple checkouts sharing the same `.git` history, so vv-git switches into one instead of rendering them side by side. Nested repositories are independent repositories and are rendered as separate blocks.

## Binary File Interception

Interception is enabled by default. Binary files are silently skipped during cursor-movement previews. When `<CR>`/`gf` encounters a binary file, vv-git opens it with the system default application instead of attempting to render a garbled diff inside Neovim.

Built-in extensions cover images (png/jpg/gif/webp/heic/…), video (mp4/mkv/mov/…), audio (mp3/wav/flac/…), archives (zip/tar/gz/tgz/jar/deb/dmg/iso/…), compiled artifacts (exe/dll/so/wasm/bin/…), fonts (ttf/otf/woff/…), binary documents (pdf/docx/xlsx/…), and databases (sqlite/db).

```lua
-- Allow specific extensions (for example, when Neovim supports image previews)
opts = {
  binary = {
    extensions = { png = false, jpg = false, jpeg = false },
  },
}

-- Disable interception completely
opts = { binary = { intercept = false } }

-- Add custom extensions
opts = { binary = { extensions = { sketch = true, fig = true } } }
```

`binary.extensions` uses `vim.tbl_deep_extend`, so you only need to specify keys to override rather than rewriting the entire table.

## Custom Colors

The `highlights` field accepts overrides for any `VVGit*` highlight group. Overrides are applied on top of defaults automatically calculated from the `Normal` background and remain active after colorscheme changes:

```lua
opts = {
  highlights = {
    -- Added lines on side b (whole-line / word-level)
    VVGitDiffAdd          = { bg = '#1a3a1a' },
    VVGitDiffChange       = { bg = '#152818' },
    VVGitDiffText         = { bg = '#2a6a2a' },
    -- Corresponding filler / deleted lines on side a
    VVGitDiffDeleteDim    = { fg = '#636b78', bg = '#1e1e2e' },
    VVGitDiffAddAsDelete  = { bg = '#4a1a1a' },
    VVGitDiffChangeDelete = { bg = '#2a1010' },
    VVGitDiffTextDelete   = { bg = '#4a1a1a' },
  },
}
```

See `lua/vv-git/hl.lua` for the complete list of overridable highlight groups.

## Keymaps

These mappings are active inside the left panel:

| Key | Description |
|------|------|
| `gf` | Jump to the file |
| `Y` | Copy the absolute file path |
| `<Tab>` | Toggle selection for the current file (multi-select; directories are ignored; configurable with `keymap_select`) |
| `<Esc>` | Clear a non-empty selection; otherwise close the panel |
| `j` / `k` / `↓` / `↑` | Jump to the next/previous selectable item (`<C-n>`/`<C-p>` are aliases; arrow keys match `j`/`k`) |
| `<CR>` / `l` / `→` | File: open its diff; directory/**section heading**: expand or collapse it (`→` matches `l`) |
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
| `gw` | Switch worktrees: list every worktree for this repository in a floating window and switch to the selected worktree to inspect its diff (equivalent to `:VVGitWorktree`) |
| `H` | Compare with HEAD: select a branch, then a commit, and show the `commit..HEAD` difference |
| `g?` | Show help |

After the first commit or after switching to an unpublished branch, the panel shows `u  Publish <branch>`. The branch name comes directly from Git, so it is never requested separately. Outside the panel, use `:VVGitPublish`

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
}
```

`get_context()` and callbacks receive a stable snapshot containing `root`, `path`, `mode`, `layout`, `panel_visible`, `from_ref`, and `to_ref`.

`compare_file` opens a native vertical diff for the current buffer or worktree file and includes unsaved lines. It additionally accepts `bufnr`; callback contexts include `root`, `path`, `ref`, `bufnr`, `source_win`, and `ref_win`.

Fields and methods whose names start with `_` are internal implementation details and are not part of the public API.

### External Event

The plugin emits this event after each repository index refresh:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'VVGitStatusChanged',
  callback = function(args)
    local root = args.data.root
  end,
})
```

The plugin also *listens* for `User VVExplorerRootChanged` (emitted by [vv-explorer](https://github.com/beixiyo/vv-explorer.nvim) when its root changes). Broadcast it from any file tree to make the panel follow:

```lua
vim.api.nvim_exec_autocmds('User', {
  pattern = 'VVExplorerRootChanged',
  data = { root = '/path/to/dir' },
})
```

While the panel is open it switches repositories only when the directory resolves to a different toplevel; when the panel is closed the directory is remembered and used as the default root on the next `open()`.
