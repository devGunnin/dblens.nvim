--- The `?` overlay is generated from the keymap registry, and has to stay readable on the
--- smallest terminal anyone runs. A hand-maintained list drifts; a panel whose right-hand column
--- falls off the screen is worse than none.
local h = require('helpers')
local help = require('dblens.ui.help')
local keymaps = require('dblens.keymaps')

local eq = h.eq

--- An 80x24 terminal, measured exactly as `help.show` measures it.
local ROWS_24, COLUMNS_80 = help.budget(24, 80)

local function options(overrides)
  return require('dblens.config').setup(overrides or {})
end

--- Every key the overlay prints, in order.
local function shown_keys(blocks)
  local out = {}
  for _, block in ipairs(blocks) do
    for _, row in ipairs(block.rows) do
      out[#out + 1] = row.left
    end
  end
  return out
end

--- Every key the registry binds for a pane, its share of the global maps included.
local function registry_keys(scope, opts)
  local out = {}
  for _, source in ipairs({ scope, 'global' }) do
    for _, entry in ipairs(keymaps.resolve(source, opts.keymaps[source])) do
      out[#out + 1] = table.concat(entry.lhs, ' / ')
    end
  end
  return out
end

local function widest(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

describe('help: the overlay is the registry', function()
  it('shows exactly the bindings that apply in each pane, nothing else', function()
    local opts = options()
    for _, scope in ipairs({ 'sidebar', 'results', 'editor' }) do
      eq(shown_keys(help.blocks(scope, opts)), registry_keys(scope, opts), {
        fail_reason = 'the ' .. scope .. ' overlay does not match what is bound',
      })
    end
  end)

  it('follows a remap instead of printing the default', function()
    local opts = options({ keymaps = { results = { sort = '<F2>' } } })
    eq(h.has(shown_keys(help.blocks('results', opts)), '<F2>'), true)
    eq(h.has(shown_keys(help.blocks('results', opts)), 's'), false)
  end)

  it('drops a binding the user turned off, and a whole scope turned off', function()
    local opts = options({ keymaps = { results = { sort = false } } })
    eq(h.has(shown_keys(help.blocks('results', opts)), 's'), false)
    local none = options({ keymaps = { global = false } })
    eq(h.has(shown_keys(help.blocks('results', none)), '<leader>dd'), false)
  end)

  it('describes every binding it lists', function()
    local opts = options()
    for _, block in ipairs(help.blocks('results', opts)) do
      eq(block.heading ~= '', true)
      for _, row in ipairs(block.rows) do
        eq(row.left ~= '' and row.right ~= '', true, { fail_reason = 'an undescribed binding' })
      end
    end
  end)
end)

describe('help: it fits the terminal it is drawn on', function()
  it('never runs a description off the right edge at 80x24', function()
    local opts = options()
    for _, scope in ipairs({ 'sidebar', 'results', 'editor' }) do
      local lines, _, fits = help.layout(help.blocks(scope, opts), ROWS_24, COLUMNS_80)
      eq(widest(lines) <= COLUMNS_80, true, {
        fail_reason = ('the %s overlay is %d columns wide at 80x24 (budget %d)'):format(
          scope,
          widest(lines),
          COLUMNS_80
        ),
      })
      -- A panel that does not fit scrolls; one that clips its text cannot be read at all.
      if fits then
        eq(#lines <= ROWS_24, true, { fail_reason = scope .. ' claimed to fit but is too tall' })
      end
    end
  end)

  --- 30 rows, not 24: the grid now binds enough keys that two columns of them do not fit 24 rows
  --- either, and there the overlay scrolls instead — which the 80x24 case above is what covers.
  --- The property here is the reflow itself: given a screen that is short but has the width, the
  --- bindings go into two columns rather than off the bottom.
  it('uses the room a large terminal has, in two columns', function()
    local opts = options()
    local blocks = help.blocks('results', opts)
    local tall = help.layout(blocks, 200, 200)
    local wide, _, fits = help.layout(blocks, 30, 200)
    eq(fits, true, { fail_reason = 'a short, wide screen could not fit the bindings at all' })
    eq(#wide < #tall, true, { fail_reason = 'a short, wide screen did not reflow into columns' })
    eq(widest(wide) > widest(tall), true)
  end)

  it('marks each heading, and only the heading text itself', function()
    local opts = options()
    for _, height in ipairs({ 200, 24 }) do
      local blocks = help.blocks('results', opts)
      local lines, headings = help.layout(blocks, height, 200)
      eq(#headings, #blocks, { fail_reason = 'wrong number of headings at height ' .. height })
      for _, span in ipairs(headings) do
        local line = lines[span.line + 1]
        eq(line ~= nil, true, { fail_reason = 'a heading points past the last line' })
        eq(span.end_col <= #line, true, { fail_reason = 'a heading runs off its line' })
        local text = line:sub(span.col + 1, span.end_col)
        -- A heading is one word; a key row would drag its description in with it.
        eq(text:find('%s') == nil and text ~= '', true, {
          fail_reason = ('heading span covers `%s`'):format(text),
        })
      end
    end
  end)

  it('still lays out when a pane has a single block left', function()
    local opts = options({ keymaps = { global = false } })
    local blocks = help.blocks('editor', opts)
    eq(#blocks > 0, true)
    local lines = help.layout(blocks, 4, 30)
    eq(#lines > 0, true)
    eq(widest(lines) > 0, true)
  end)
end)
