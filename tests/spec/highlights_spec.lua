--- Every DbLens group has to exist, follow the colorscheme rather than a hardcoded colour, and
--- stay override-able. The one that matters most is the mode indicator: LOCKED and EDIT looking
--- alike is the difference between knowing and not knowing that a keystroke can write.
local h = require('helpers')
local highlights = require('dblens.ui.highlights')

local eq, neq = h.eq, h.neq

local function resolved(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

local function is_empty(spec)
  return next(spec) == nil
end

--- `highlight clear` is global and permanent, and these cases also leave `DbLensNull` pinned to a
--- test colour plus a live `ColorScheme` autocmd. Restoring the colorscheme after each one keeps
--- every alphabetically-later spec running against the same highlights it would see alone.
local function restore_colors()
  vim.cmd('highlight clear')
  local scheme = vim.g.colors_name
  if scheme and scheme ~= '' then
    pcall(vim.cmd.colorscheme, scheme)
  end
  require('dblens.ui.highlights').setup({})
end

describe('highlights: the groups exist', function()
  after_each(restore_colors)

  before_each(function()
    vim.cmd('highlight clear')
    highlights.setup({})
  end)

  it('defines every group it documents', function()
    local groups = highlights.groups()
    eq(#groups > 20, true, { fail_reason = 'the group list looks truncated' })
    for _, group in ipairs(groups) do
      eq(is_empty(resolved(group)), false, { fail_reason = group .. ' resolves to nothing' })
    end
  end)

  it('derives every group from a standard one instead of naming a colour', function()
    for _, group in ipairs(highlights.groups()) do
      local raw = vim.api.nvim_get_hl(0, { name = group })
      local linked = raw.link ~= nil
      -- A group carrying an attribute of its own cannot also be a link, so it inherits the
      -- linked group's colours explicitly; either way it must resolve to something.
      eq(linked or not is_empty(raw), true, { fail_reason = group .. ' is neither linked nor set' })
    end
  end)

  it('lists the groups in a stable, sorted order', function()
    local groups = highlights.groups()
    local sorted = vim.deepcopy(groups)
    table.sort(sorted)
    eq(groups, sorted)
  end)

  it('names the pane chrome in its winhighlight', function()
    eq(highlights.winhighlight(false):find('EndOfBuffer:DbLensNormal', 1, true) ~= nil, true, {
      fail_reason = 'the empty part of a pane keeps a background of its own',
    })
    for _, group in ipairs({ 'DbLensNormal', 'DbLensCursorLine', 'DbLensWinBar' }) do
      eq(highlights.winhighlight(false):find(group, 1, true) ~= nil, true, {
        fail_reason = group .. ' is not in the pane winhighlight',
      })
    end
  end)

  it('recolours the statusline only when dblens draws the separator itself', function()
    eq(highlights.winhighlight(true):find('StatusLine:DbLensRule', 1, true) ~= nil, true)
    eq(highlights.winhighlight(false):find('StatusLine', 1, true), nil, {
      fail_reason = 'a user keeping their own statusline had its colours taken over',
    })
  end)
end)

describe('highlights: LOCKED and EDIT', function()
  after_each(restore_colors)

  before_each(function()
    vim.cmd('highlight clear')
    highlights.setup({})
  end)

  it('never renders the two modes the same way', function()
    local locked, edit = resolved('DbLensLocked'), resolved('DbLensEdit')
    eq(is_empty(locked), false)
    eq(is_empty(edit), false)
    neq(vim.inspect(locked), vim.inspect(edit))
  end)

  -- Weight is the part dblens controls: the hue comes from DiagnosticOk and DiagnosticWarn,
  -- which a colorscheme owns, so only the bold on EDIT is guaranteed here.
  it('gives EDIT extra weight of its own, whatever the colorscheme does', function()
    eq(resolved('DbLensEdit').bold, true)
    neq(resolved('DbLensEdit').fg, resolved('DbLensLocked').fg)
  end)
end)

describe('highlights: overrides', function()
  after_each(restore_colors)

  before_each(function()
    vim.cmd('highlight clear')
  end)

  it('lets setup{} win over the derived link', function()
    highlights.setup({ DbLensNull = { fg = '#123456' } })
    eq(resolved('DbLensNull').fg, tonumber('123456', 16))
  end)

  it('lets a colorscheme that defines a DbLens group win over the default link', function()
    vim.api.nvim_set_hl(0, 'DbLensNull', { fg = '#abcdef' })
    highlights.setup({})
    eq(resolved('DbLensNull').fg, tonumber('abcdef', 16))
  end)

  it('re-derives everything, overrides included, on a colorscheme change', function()
    highlights.setup({ DbLensNull = { fg = '#123456' } })
    vim.cmd('highlight clear')
    vim.api.nvim_exec_autocmds('ColorScheme', {})
    eq(resolved('DbLensNull').fg, tonumber('123456', 16))
    eq(is_empty(resolved('DbLensHeader')), false)
  end)
end)
