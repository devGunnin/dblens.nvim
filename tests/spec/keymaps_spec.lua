--- The keymap registry is the single source of truth for bindings, the `?` overlay and the
--- documentation. These cases hold it to that: no two keys in a window can collide, no binding
--- can shadow something the user needs in a buffer they type in, and neither table of docs can
--- drift from what is actually bound.
local h = require('helpers')
local keymaps = require('dblens.keymaps')

local eq, expect_error = h.eq, h.expect_error

local SCOPES = { 'global', 'connections', 'sidebar', 'results', 'editor' }

--- Every (lhs, mode) a scope binds, as a flat list.
local function bound_keys(scope)
  local out = {}
  for _, entry in ipairs(keymaps.resolve(scope, nil)) do
    local modes = type(entry.spec.mode) == 'table' and entry.spec.mode or { entry.spec.mode }
    for _, mode in ipairs(modes) do
      for _, lhs in ipairs(entry.lhs) do
        out[#out + 1] = { lhs = lhs, mode = mode, action = entry.spec.action }
      end
    end
  end
  return out
end

describe('keymaps: registry shape', function()
  it('declares an action, a key, a description, a mode and a group for every binding', function()
    for _, scope in ipairs(SCOPES) do
      for _, spec in ipairs(keymaps.specs[scope]) do
        local where = scope .. '.' .. tostring(spec.action)
        eq(type(spec.action), 'string', { fail_reason = where .. ' has no action' })
        eq(spec.desc ~= nil and spec.desc ~= '', true, { fail_reason = where .. ' has no desc' })
        eq(type(spec.group), 'string', { fail_reason = where .. ' has no group' })
        eq(
          type(spec.mode) == 'string' or vim.islist(spec.mode),
          true,
          { fail_reason = where .. ' has a bad mode' }
        )
        eq(
          type(spec.lhs) == 'string' or vim.islist(spec.lhs),
          true,
          { fail_reason = where .. ' has a bad lhs' }
        )
      end
    end
  end)

  it('names each action once per scope', function()
    for _, scope in ipairs(SCOPES) do
      local seen = {}
      for _, spec in ipairs(keymaps.specs[scope]) do
        eq(
          seen[spec.action],
          nil,
          { fail_reason = scope .. ' declares ' .. spec.action .. ' twice' }
        )
        seen[spec.action] = true
      end
    end
  end)
end)

describe('keymaps: conflicts', function()
  it('binds no key twice in the same window and mode', function()
    for _, scope in ipairs(SCOPES) do
      local seen = {}
      for _, key in ipairs(bound_keys(scope)) do
        local at = key.mode .. ' ' .. key.lhs
        eq(seen[at], nil, {
          fail_reason = ('%s binds `%s` to both %s and %s'):format(
            scope,
            at,
            tostring(seen[at]),
            key.action
          ),
        })
        seen[at] = key.action
      end
    end
  end)

  it('leaves the SQL editor its own backwards search', function()
    -- The editor is the one dblens buffer the user types in; `?` there belongs to them.
    for _, key in ipairs(bound_keys('editor')) do
      eq(key.lhs == '?', false, { fail_reason = 'the editor binds a bare `?` to ' .. key.action })
    end
    eq(keymaps.lhs_for('editor', 'help', nil), '<localleader>?')
    eq(keymaps.lhs_for('sidebar', 'help', nil), '?')
    eq(keymaps.lhs_for('results', 'help', nil), '?')
  end)

  it('keeps every global binding under one prefix', function()
    for _, key in ipairs(bound_keys('global')) do
      eq(key.lhs:sub(1, 9), '<leader>d', {
        fail_reason = ('global action %s is bound outside the prefix: %s'):format(
          key.action,
          key.lhs
        ),
      })
    end
  end)
end)

--- `<leader>d` is the debug prefix in LazyVim, AstroNvim and most kickstart configs, and seven of
--- the twelve global keys collide with LazyVim's dap set. `vim.keymap.set` overwrites in silence,
--- so the user's continue key becomes a connection picker with nothing to explain it.
describe('keymaps: taking a global key over from another plugin', function()
  local dblens = require('dblens')

  after_each(function()
    pcall(vim.keymap.del, 'n', '<leader>dc')
    dblens.setup({})
  end)

  it('records what it overwrote so checkhealth can report it', function()
    vim.keymap.set('n', '<leader>dc', function() end, { desc = 'Debug: continue' })
    dblens.setup({})
    local taken = dblens.keymaps_taken_over()
    local found
    for _, entry in ipairs(taken) do
      if entry.lhs == '<leader>dc' then
        found = entry
      end
    end
    eq(type(found), 'table', { fail_reason = 'the collision was not recorded' })
    eq(found.previous, 'Debug: continue')
  end)

  it('does not report its own bindings as a takeover', function()
    dblens.setup({})
    dblens.setup({})
    eq(dblens.keymaps_taken_over(), {}, {
      fail_reason = 'a second setup{} must not report re-binding its own keys',
    })
  end)
end)

describe('keymaps.lhs_for', function()
  it('answers with the key the action is actually bound to', function()
    eq(keymaps.lhs_for('global', 'connections', nil), '<leader>dc')
    eq(keymaps.lhs_for('sidebar', 'select', nil), '<CR>')
  end)

  it('follows a remap, and reports nothing when the action is turned off', function()
    eq(keymaps.lhs_for('global', 'connections', { connections = '<F5>' }), '<F5>')
    eq(keymaps.lhs_for('global', 'connections', { connections = false }), nil)
    eq(keymaps.lhs_for('global', 'connections', false), nil)
  end)

  it('refuses an action that does not exist rather than reporting nothing', function()
    expect_error(function()
      keymaps.lhs_for('results', 'nosuchaction', { nosuchaction = 'x' })
    end, 'nosuchaction')
  end)
end)

describe('keymaps: the which-key prefix', function()
  local whichkey = require('dblens.ui.whichkey')

  it('finds the prefix the default global bindings share', function()
    local lhs = {}
    for _, key in ipairs(bound_keys('global')) do
      lhs[#lhs + 1] = key.lhs
    end
    eq(whichkey.common_prefix(lhs), '<leader>d')
  end)

  it('reports none when the bindings share no whole key', function()
    eq(whichkey.common_prefix({ '<leader>x', '<localleader>y' }), nil)
    eq(whichkey.common_prefix({ '<leader>dd', 'gx' }), nil)
    eq(whichkey.common_prefix({ '<leader>dd' }), nil)
  end)

  it('reports none when one binding IS the prefix, which has no menu to label', function()
    eq(whichkey.common_prefix({ '<leader>d', '<leader>dd' }), nil)
  end)

  it('does nothing at all when which-key is not installed', function()
    local options = require('dblens.config').setup({})
    h.expect_no_error(function()
      whichkey.setup(options)
    end)
  end)
end)

--- The rows of one `### Heading` table in the README, as lists of cell strings.
local function readme_rows(heading)
  local readme = h.repo_file('README.md')
  local section = readme:match('\n### ' .. heading .. '\n(.-)\n#')
  assert(section, ('no README section `### %s`'):format(heading))
  local rows = {}
  for line in section:gmatch('[^\n]+') do
    if line:sub(1, 1) == '|' and not line:find('^|%s*[-:| ]+|$') then
      local cells = {}
      for cell in line:gmatch('|([^|]*)') do
        cells[#cells + 1] = vim.trim(cell)
      end
      -- The trailing `|` yields one empty cell.
      table.remove(cells)
      rows[#rows + 1] = cells
    end
  end
  table.remove(rows, 1) -- the header row
  return rows
end

--- What the registry says a documentation row for this scope should read.
local function expected_rows(scope, with_mode)
  local rows = {}
  for _, entry in ipairs(keymaps.resolve(scope, nil)) do
    local keys = {}
    for _, lhs in ipairs(entry.lhs) do
      keys[#keys + 1] = '`' .. lhs .. '`'
    end
    local row = { table.concat(keys, ' / ') }
    if with_mode then
      row[#row + 1] = type(entry.spec.mode) == 'table' and table.concat(entry.spec.mode, '')
        or entry.spec.mode
    end
    row[#row + 1] = '`' .. entry.spec.action .. '`'
    row[#row + 1] = entry.spec.desc
    rows[#rows + 1] = row
  end
  return rows
end

describe('keymaps: the README describes what is bound', function()
  local SECTIONS = {
    { scope = 'global', heading = 'Global', mode = false },
    { scope = 'connections', heading = 'Connections manager', mode = false },
    { scope = 'sidebar', heading = 'Sidebar', mode = false },
    { scope = 'results', heading = 'Results grid', mode = false },
    { scope = 'editor', heading = 'SQL editor', mode = true },
  }

  it('lists every binding, in order, with its key, action and description', function()
    for _, section in ipairs(SECTIONS) do
      eq(readme_rows(section.heading), expected_rows(section.scope, section.mode), {
        fail_reason = ('the README `### %s` table no longer matches the registry'):format(
          section.heading
        ),
      })
    end
  end)
end)

describe('keymaps: the vimdoc describes what is bound', function()
  it('carries a line naming both the key and the action for every binding', function()
    local doc = h.repo_file('doc/dblens.txt')
    for _, scope in ipairs(SCOPES) do
      for _, entry in ipairs(keymaps.resolve(scope, nil)) do
        local key = '`' .. entry.lhs[1] .. '`'
        local pattern = vim.pesc(key) .. '.*%f[%w]' .. vim.pesc(entry.spec.action) .. '%f[%W]'
        eq(doc:find(pattern) ~= nil, true, {
          fail_reason = ('doc/dblens.txt has no line for %s %s (%s)'):format(
            key,
            entry.spec.action,
            scope
          ),
        })
      end
    end
  end)
end)
