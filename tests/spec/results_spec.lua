--- `current_cell` maps the cursor's byte column to a grid column via `virtcol`, which wants a
--- 1-based column and was handed a 0-based one -- every one of the 14 cell actions (`F` filter,
--- `s` sort, `gf` FK, `e` edit, ...) resolves the wrong column whenever the cursor sits on a
--- column's FIRST character, including right where a search match parks it (`focus_match`).
---
--- The byte positions below are read off the grid's own render, not guessed: one row,
--- `id | café | oslo`, rendered as `"  1 │ café │ oslo "` with spans `{2,3} {7,10} {14,17}`
--- (display columns). `café` puts a 2-byte UTF-8 character (`é`) inside the span under test.
local h = require('helpers')
local results = require('dblens.ui.results')

local eq = h.eq

local RELATION = { name = 'orders', kind = 'table' }
local ROW = { '1', 'café', 'oslo' }
local COLUMNS = { 'id', 'name', 'city' }

local function scratch_options(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
    discovery = { auto = false },
  }, extra or {})
end

--- A UI open on a result the spec built directly, so nothing depends on a client.
local function open_with_result()
  local app = require('dblens.app')
  require('dblens.config').setup(scratch_options())
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.grid.source = { kind = 'query', sql = 'select', label = 'query' }
  state.grid.result = { columns = COLUMNS, rows = { ROW }, malformed = 0 }
  results.render(state)
  return app, state
end

--- Put the cursor at a 0-based byte column on the one data row.
---
--- `virtcol` reads the CURRENT window, which the results window always is when a real keymap
--- fires (it is bound on that buffer) -- so the test has to focus it too, not just move the
--- cursor, or `current_cell` reads virtcol against whatever window happens to be current.
local function cell_at(state, byte_col)
  vim.api.nvim_set_current_win(state.layout.wins.results)
  vim.api.nvim_win_set_cursor(state.layout.wins.results, { state.grid.header_lines + 1, byte_col })
  return results.current_cell(state)
end

--- Call the Lua callback a `results` keymap is bound to, without switching any window's buffer.
local function press(state, lhs)
  local mapping
  vim.api.nvim_buf_call(state.layout.bufs.results, function()
    mapping = vim.fn.maparg(lhs, 'n', false, true)
  end)
  assert(type(mapping.callback) == 'function', ('no handler bound to `%s`'):format(lhs))
  mapping.callback()
end

describe('results: current_cell resolves the byte the cursor is on', function()
  local app

  after_each(function()
    if app then
      app.close()
      app = nil
    end
  end)

  it('resolves the FIRST byte of a cell to that cell, not the one before it', function()
    local state
    app, state = open_with_result()
    -- byte 8 is 'c' of café, the first byte of column 2's span (display col 7). The bug this
    -- fix corrects: unpatched code reads virtcol at byte 7 instead and answers column 1.
    local cell = cell_at(state, 8)
    eq(cell.name, 'name', { fail_reason = 'first-char cursor resolved to the wrong column' })
    eq(cell.value, 'café')
  end)

  it('resolves the first byte of the LAST column too', function()
    local state
    app, state = open_with_result()
    -- byte 18 is 'o' of oslo, the first byte of column 3's span.
    eq(cell_at(state, 18).name, 'city')
  end)

  it('resolves a middle byte of a cell', function()
    local state
    app, state = open_with_result()
    eq(cell_at(state, 9).name, 'name') -- 'a' of café
  end)

  it('resolves the last byte of a cell', function()
    local state
    app, state = open_with_result()
    eq(cell_at(state, 2).name, 'id') -- '1', the only byte of the id column's value
    eq(cell_at(state, 21).name, 'city') -- second 'o' of oslo
  end)

  it('resolves a separator byte to the column at-or-before it', function()
    local state
    app, state = open_with_result()
    eq(cell_at(state, 3).name, 'id', { fail_reason = 'the space before the first separator' })
    eq(cell_at(state, 14).name, 'name', { fail_reason = 'the separator after café' })
  end)

  it('resolves both bytes of a multibyte character to the same column', function()
    local state
    app, state = open_with_result()
    eq(cell_at(state, 11).name, 'name') -- first byte of 'é'
    eq(cell_at(state, 12).name, 'name') -- second byte of 'é'
  end)
end)

describe('results: cell actions target the column the cursor is actually on', function()
  local app

  after_each(function()
    if app then
      app.close()
      app = nil
    end
  end)

  it(
    'F opens the filter builder on the right column when the cursor is on its first char',
    function()
      local state
      app, state = open_with_result()
      results.attach(state)
      vim.api.nvim_set_current_win(state.layout.wins.results)
      vim.api.nvim_win_set_cursor(state.layout.wins.results, { state.grid.header_lines + 1, 8 })

      local filterbuilder = require('dblens.ui.filterbuilder')
      local real_open = filterbuilder.open
      local received
      filterbuilder.open = function(_, cell)
        received = cell
      end
      local ok, err = pcall(press, state, 'F')
      filterbuilder.open = real_open
      assert(ok, tostring(err))

      assert(received, 'F did not reach the filter builder')
      eq(received.name, 'name', { fail_reason = 'F opened the builder on the wrong column' })
    end
  )

  it('s sorts by the right column when the cursor is on its first char', function()
    local sent = {}
    h.with_fake_exec(function(call)
      if call.stdin and call.stdin:find('SELECT * FROM', 1, true) then
        sent[#sent + 1] = call.stdin
        return { stdout = h.wire({ h.record('1', 'café', 'oslo') }) }
      end
      return {}
    end, function(session_mod)
      local options = scratch_options()
      local a = require('dblens.app')
      require('dblens.config').setup(options)
      a.open()
      local state = a.state()
      assert(state, 'app.open left no state')
      state.session = h.fake_session(session_mod, {}, options)
      state.grid.source = { kind = 'relation', relation = RELATION, label = 'orders' }
      state.grid.result = { columns = COLUMNS, rows = { ROW }, malformed = 0 }
      results.render(state)
      results.attach(state)

      vim.api.nvim_set_current_win(state.layout.wins.results)
      vim.api.nvim_win_set_cursor(state.layout.wins.results, { state.grid.header_lines + 1, 8 })
      press(state, 's')

      assert(#sent > 0, 'the grid never queried a page')
      eq(sent[#sent]:find('ORDER BY "name"', 1, true) ~= nil, true, {
        fail_reason = 's sorted by the wrong column: ' .. sent[#sent],
      })
      a.close()
    end)
  end)
end)
