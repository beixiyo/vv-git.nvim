-- 高亮组注册；ColorScheme 时重新应用（VVGitDiff* 强制覆盖，其余 default=true）

local M = {}


---@return table specs  { name = vim.api.keyset.highlight }
local function build_specs()
  local add_line = '#323C33'   -- 新增行背景（整行 context）
  local del_line = '#2D1615'   -- 删除行背景（整行 context）
  local add_text = '#3E5633'   -- 实际新增文字背景
  local del_text = '#621D21'   -- 实际删除文字背景

  return {
    -- diff 主体（b 侧/绿系由 VVGitDiffAdd/Change/Text 提供；a 侧/红系由
    -- VVGitDiffAddAsDelete/ChangeDelete/TextDelete 提供；DiffDelete 两侧都 dim）
    --
    -- DiffTextAdd 是 nvim 0.11+ 配合 diffopt:inline:char/word 引入的新组：
    --   在 changed line 内，"对侧无对应原文"的纯增 / 纯删字符走它，"两侧都有但内容不同"
    --   的字符走 DiffText。视觉上同色即可——区分意义不大，缺映射会 fall-through 到全局
    --   默认色，破坏深 / 浅对比节奏
    VVGitDiffAdd            = { bg = add_text },   -- pure-add line: bright green
    VVGitDiffChange         = { bg = add_line },   -- changed line context: light green
    VVGitDiffText           = { bg = add_text },   -- intra-line added chars: bright green
    VVGitDiffTextAdd        = { bg = add_text },
    VVGitDiffAddAsDelete    = { bg = del_text },   -- pure-delete line: bright red
    VVGitDiffChangeDelete   = { bg = del_line },   -- changed line context: light red
    VVGitDiffTextDelete     = { bg = del_text },   -- intra-line deleted chars: bright red
    VVGitDiffTextAddDelete  = { bg = del_text },
    VVGitDiffDeleteDim      = { fg = '#636b78', bg = add_line },

    -- 左栏
    VVGitPanelSection   = { link = 'Title' },
    VVGitPanelSectionCount = { link = 'Comment' },
    VVGitPanelDir       = { link = 'Directory' },
    VVGitPanelStagedDir = { link = 'Keyword' },
    VVGitPanelSubrepo   = { link = 'Special', bold = true }, -- 子仓库块标题：跟随主题（Special）+ 加粗，与普通目录拉开
    VVGitPanelBranch    = { link = 'Comment' }, -- 仓库标题行的分支名（ 󰘬 <branch>）：低调跟随主题
    VVGitPanelFile      = { link = 'Normal' },
    VVGitPanelIndent    = { link = 'Comment' },
    VVGitPanelMatch     = { link = 'Search' },
    VVGitPanelDim       = { link = 'Comment' },
    VVGitPanelSelected  = { link = 'Visual' },

    -- diff 折叠行：走 Comment 色，切主题自动适配
    VVGitFold           = { link = 'Comment' },

    -- commit box
    VVGitCommitHint     = { link = 'Comment' },
    VVGitCommitBorder   = { link = 'FloatBorder' },
    VVGitCommitTitle    = { link = 'Title' },

    -- 冲突 diff winbar：branch badge 颜色与 a/b 侧色系对应
    VVGitWinbarOurs     = { fg = '#c74e39', bold = true },  -- 红系，对应 a_win
    VVGitWinbarTheirs   = { fg = '#73c991', bold = true },  -- 绿系，对应 b_win
  }
end

-- diff 主体的颜色组要"权威"，每次 setup / ColorScheme 都覆盖；其余偏 UI 风格的
-- 组（panel / commit / fold）才用 default=true，让用户的 colorscheme 能自定义
--
-- 之前所有组都加 default=true，导致同一会话里改 alpha 后再 setup 时新色值是 no-op
-- （:hi default 语义就是"已存在就不覆盖"），必须 nvim 重启才生效
--
-- 用前缀匹配区分两类：VVGitDiff* 强制 set；其余（VVGitPanel*/VVGitFold/VVGitCommit*）
-- 走 default。比维护一张白名单更稳——新增 diff 色组不会忘记同步
local user_overrides = {}

local function apply()
  local specs = build_specs()
  for name, override in pairs(user_overrides) do
    specs[name] = vim.tbl_extend('force', specs[name] or {}, override)
  end
  for name, spec in pairs(specs) do
    if spec.default == nil and not name:match('^VVGitDiff') then
      spec.default = true
    end
    vim.api.nvim_set_hl(0, name, spec)
  end
end

---@param opts? { highlights?: table<string, vim.api.keyset.highlight> }
function M.setup(opts)
  user_overrides = (opts and opts.highlights) or {}
  -- 共享 git 状态色（VVGitAdded/Modified/...）统一由 vv-utils.git 注册
  require('vv-utils.git').register_hl()
  apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('VVGitHL', { clear = true }),
    callback = apply,
  })
end

return M
