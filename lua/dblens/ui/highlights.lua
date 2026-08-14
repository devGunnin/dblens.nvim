--- Highlight groups, derived from whatever colorscheme is active.
---
--- Every group links to a standard group rather than naming a colour, so dblens inherits the
--- user's theme automatically and follows a `:colorscheme` change. All links are set with
--- `default = true`, so a colorscheme that defines a `DbLens*` group wins; explicit overrides
--- from `setup{}` are applied afterwards and win over both.
local M = {}

--- group -> standard group it follows.
local LINKS = {
  DbLensNormal = 'Normal',
  DbLensTitle = 'Title',
  DbLensDim = 'Comment',
  DbLensAccent = 'Identifier',
  DbLensBorder = 'FloatBorder',
  DbLensMatch = 'Search',
  DbLensError = 'DiagnosticError',
  DbLensWarn = 'DiagnosticWarn',
  DbLensOk = 'DiagnosticOk',

  -- tree
  DbLensSchema = 'Directory',
  DbLensTable = 'Normal',
  DbLensView = 'Type',
  DbLensColumn = 'Normal',
  DbLensDataType = 'Comment',
  DbLensIcon = 'Special',
  DbLensChevron = 'Comment',
  DbLensPK = 'Special',
  DbLensFK = 'Type',
  DbLensNN = 'Comment',
  DbLensIndex = 'Constant',

  -- grid
  DbLensHeader = 'Title',
  -- NonText, not WinSeparator: many colorschemes give WinSeparator a background, which turns the
  -- header rule into a filled bar instead of a line.
  DbLensRule = 'NonText',
  DbLensNull = 'Comment',
  DbLensNumber = 'Number',
  DbLensBoolean = 'Boolean',
  DbLensString = 'Normal',
  DbLensDirty = 'DiffChange',
  DbLensSortKey = 'Search',

  -- status
  DbLensStatus = 'StatusLine',
  DbLensSpinner = 'DiagnosticInfo',
  DbLensReadOnly = 'DiagnosticWarn',
  DbLensTxn = 'DiagnosticInfo',
}

--- Groups that read better with an attribute of their own on top of the link.
local ATTRS = {
  DbLensHeader = { bold = true },
  DbLensTitle = { bold = true },
  DbLensNull = { italic = true },
  DbLensPK = { bold = true },
}

local applied_overrides = {}

local function apply(overrides)
  for group, link in pairs(LINKS) do
    local attrs = ATTRS[group]
    if attrs then
      -- `link` and attributes are mutually exclusive, so inherit the linked group's colours
      -- explicitly and add the attribute on top.
      local base = vim.api.nvim_get_hl(0, { name = link, link = false })
      local spec = vim.tbl_extend('force', {}, base, attrs)
      vim.api.nvim_set_hl(0, group, vim.tbl_extend('force', spec, { default = true }))
    else
      vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
  end
  for group, spec in pairs(overrides or {}) do
    vim.api.nvim_set_hl(0, group, spec)
  end
end

--- Define the groups and keep them in step with the colorscheme.
---@param overrides table<string, table>?
function M.setup(overrides)
  applied_overrides = overrides or {}
  apply(applied_overrides)
  local group = vim.api.nvim_create_augroup('DbLensHighlights', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    desc = 'dblens: re-derive highlights from the new colorscheme',
    callback = function()
      apply(applied_overrides)
    end,
  })
end

--- Every group dblens defines, for the documentation and `:checkhealth`.
---@return string[]
function M.groups()
  local out = vim.tbl_keys(LINKS)
  table.sort(out)
  return out
end

return M
