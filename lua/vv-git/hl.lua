-- 高亮组注册：仿照仓库 diffview.lua 的 alpha 混色思路
-- 每次 ColorScheme 触发都重新从 Normal.bg 计算，保证切主题时配色跟随

local M = {}

local function hex_rgb(h)
  return tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16)
end

---@param argb string #RRGGBBAA
---@param base_hex string #RRGGBB
---@return string #RRGGBB
local function mix_over(argb, base_hex)
  local fr, fg, fb = hex_rgb(argb:sub(1, 7))
  local a = tonumber(argb:sub(8, 9), 16) / 255
  local r0, g0, b0 = hex_rgb(base_hex)
  return string.format(
    '#%02x%02x%02x',
    math.floor(fr * a + r0 * (1 - a)),
    math.floor(fg * a + g0 * (1 - a)),
    math.floor(fb * a + b0 * (1 - a))
  )
end

---@return table specs  { name = vim.api.keyset.highlight }
local function build_specs()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
  local base = normal.bg and string.format('#%06x', normal.bg) or '#1e1e1e'
  local function mix(argb) return mix_over(argb, base) end

  -- 整行 / 词级：alpha 与 vsc-theme (beixiyo/vsc-theme) 原版一致
  --   line: 0x21 (add) / 0x55 (del)
  --   word: 0x22 / 0x22 —— 叠在整行色上，对比靠"双层叠加"产生（VSC 模型）
  -- 之前为了"看得清"拉到 0x99/0xaa，结果颜色过饱和浮夸，回到原版数值
  local add_line = mix('#8cc26521')
  local del_line = mix('#50101555')
  local add_text = mix_over('#85e73422', add_line)
  local del_text = mix_over('#ed344322', del_line)

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
    VVGitDiffDeleteDim      = { fg = '#636b78' },

    -- 左栏
    VVGitPanelSection   = { link = 'Title' },
    VVGitPanelSectionCount = { link = 'Comment' },
    VVGitPanelDir       = { link = 'Directory' },
    VVGitPanelStagedDir = { link = 'Keyword' },
    VVGitPanelFile      = { link = 'Normal' },
    VVGitPanelIndent    = { link = 'Comment' },
    VVGitPanelMatch     = { link = 'Search' },
    VVGitPanelDim       = { link = 'Comment' },
    VVGitPanelSelected  = { link = 'CursorLine' },

    -- diff 折叠行：走 Comment 色，切主题自动适配
    VVGitFold           = { link = 'Comment' },

    -- commit box
    VVGitCommitHint     = { link = 'Comment' },
    VVGitCommitBorder   = { link = 'FloatBorder' },
    VVGitCommitTitle    = { link = 'Title' },
  }
end

-- diff 主体的颜色组要"权威"，每次 setup / ColorScheme 都覆盖；其余偏 UI 风格的
-- 组（panel / commit / fold）才用 default=true，让用户的 colorscheme 能自定义
--
-- 之前所有组都加 default=true，导致同一会话里改 alpha 后再 setup 时新色值是 no-op
-- （:hi default 语义就是"已存在就不覆盖"），必须 nvim 重启才生效。
--
-- 用前缀匹配区分两类：VVGitDiff* 强制 set；其余（VVGitPanel*/VVGitFold/VVGitCommit*）
-- 走 default。比维护一张白名单更稳——新增 diff 色组不会忘记同步
local function apply()
  for name, spec in pairs(build_specs()) do
    if spec.default == nil and not name:match('^VVGitDiff') then
      spec.default = true
    end
    vim.api.nvim_set_hl(0, name, spec)
  end
end

function M.setup()
  -- 共享 git 状态色（VVGitAdded/Modified/...）统一由 vv-utils.git 注册
  require('vv-utils.git').register_hl()
  apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('VVGitHL', { clear = true }),
    callback = apply,
  })
end

return M
