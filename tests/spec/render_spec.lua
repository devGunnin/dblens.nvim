--- The results grid draws its highlights in scheduled chunks. A wide page carries tens of
--- thousands of extmarks and setting them all in one tick is what makes a grid feel janky, so
--- these cases hold the render path to painting incrementally and to dropping the work of a
--- render that has been superseded.
local h = require('helpers')
local results = require('dblens.ui.results')

local eq = h.eq

local NAMESPACE = vim.api.nvim_create_namespace('dblens.results')

local function scratch_options(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
  }, extra or {})
end

--- The UI open on a result the spec built directly, so nothing depends on a client.
local function open_with_result(rows, columns, extra)
  local app = require('dblens.app')
  require('dblens.config').setup(scratch_options(extra))
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.grid.source = { kind = 'query', sql = 'select', label = 'query' }
  state.grid.result = { columns = columns, rows = rows, malformed = 0 }
  return app, state
end

local function mark_count(state)
  return #vim.api.nvim_buf_get_extmarks(state.layout.bufs.results, NAMESPACE, 0, -1, {})
end

--- Let every scheduled chunk run, and say how many marks ended up on the buffer.
local function drain(state, expected)
  vim.wait(2000, function()
    return mark_count(state) >= expected
  end, 5)
  return mark_count(state)
end

local function grid_rows(count, width)
  local rows = {}
  for r = 1, count do
    local row = {}
    for c = 1, width do
      row[c] = ('r%dc%d'):format(r, c)
    end
    rows[r] = row
  end
  return rows
end

local function grid_columns(width)
  local columns = {}
  for c = 1, width do
    columns[c] = 'col' .. c
  end
  return columns
end

describe('results: a large page is painted in chunks', function()
  local app

  after_each(function()
    if app then
      app.close()
      app = nil
    end
  end)

  it('leaves the first tick holding one chunk, not the whole page', function()
    local chunk = 50
    local state
    app, state = open_with_result(grid_rows(200, 4), grid_columns(4), {
      ui = { grid = { chunk_size = chunk } },
    })
    results.render(state)

    local immediate = mark_count(state)
    eq(immediate, chunk, {
      fail_reason = ('the first tick set %d marks; a chunk is %d'):format(immediate, chunk),
    })

    -- 200 rows x 4 text cells, plus the header and its rule.
    local total = 200 * 4 + 2
    eq(drain(state, total), total, { fail_reason = 'the remaining chunks never ran' })
  end)

  it('paints a page that fits in one chunk without scheduling anything', function()
    local state
    app, state = open_with_result(grid_rows(2, 2), grid_columns(2), {
      ui = { grid = { chunk_size = 500 } },
    })
    results.render(state)
    eq(mark_count(state), 2 * 2 + 2)
  end)

  --- `config.validate` refuses this now, so reaching it means something bypassed validation —
  --- and the old loop's answer to a zero chunk was to reschedule itself forever at 100% CPU with
  --- SIGTERM ignored. A render must terminate whatever it is handed.
  it('still terminates when handed a chunk size that cannot advance', function()
    local state
    app, state = open_with_result(grid_rows(20, 2), grid_columns(2), {})
    state.options.ui.grid.chunk_size = 0
    results.render(state)

    local total = 20 * 2 + 2
    eq(drain(state, total), total, { fail_reason = 'the render never finished the page' })
  end)

  it('drops the chunks of a superseded render instead of stacking them', function()
    local state
    app, state = open_with_result(grid_rows(200, 4), grid_columns(4), {
      ui = { grid = { chunk_size = 50 } },
    })
    results.render(state)
    state.grid.result = { columns = grid_columns(2), rows = grid_rows(3, 2), malformed = 0 }
    results.render(state)

    local total = 3 * 2 + 2
    eq(drain(state, total), total, {
      fail_reason = 'the abandoned render kept writing marks over the new one',
    })
    eq(vim.api.nvim_buf_line_count(state.layout.bufs.results), 3 + 2)
  end)
end)

--- The needle list is matched as a substring, so `interval` and `point` both contain `int` and
--- were coloured and aligned as numbers. SQL Server's boolean is `bit`, which matched nothing.
describe('grid: a declared type decides the colour', function()
  local grid = require('dblens.render.grid')

  local function hl_of(declared, value)
    local out = grid.render({
      columns = { 'c' },
      rows = { { value } },
      types = { declared },
      max_col_width = 40,
      null_display = 'NULL',
      separator = '│',
      truncation = '…',
    })
    for _, mark in ipairs(out.marks) do
      if mark.line == 2 then
        return mark.hl
      end
    end
    return nil
  end

  it('classifies the types that only look numeric', function()
    eq(hl_of('integer', '1'), 'DbLensNumber')
    eq(hl_of('numeric', '1.5'), 'DbLensNumber')
    eq(hl_of('interval', '3 days 04:00:00'), 'DbLensString')
    eq(hl_of('point', '(1,2)'), 'DbLensString')
    eq(hl_of('bit', '1'), 'DbLensBoolean')
    eq(hl_of('boolean', 't'), 'DbLensBoolean')
  end)
end)

describe('results: the empty states', function()
  local app

  after_each(function()
    if app then
      app.close()
      app = nil
    end
  end)

  local function lines(state)
    return vim.api.nvim_buf_get_lines(state.layout.bufs.results, 0, -1, false)
  end

  it('says a table with no matching rows is empty, keeping its header', function()
    local state
    app, state = open_with_result({}, { 'id', 'name' })
    results.render(state)
    local shown = lines(state)
    eq(shown[1]:find('id', 1, true) ~= nil, true, { fail_reason = 'the header went missing' })
    eq(shown[#shown]:find('no rows', 1, true) ~= nil, true)
  end)

  it('puts the cursor on the first data row, not the header it cannot act on', function()
    local state
    app, state = open_with_result(grid_rows(4, 2), grid_columns(2))
    vim.api.nvim_win_set_cursor(state.layout.wins.results, { 1, 0 })
    results.render(state)
    eq(vim.api.nvim_win_get_cursor(state.layout.wins.results)[1], 3)
  end)

  it('leaves the cursor alone once it is on a data row', function()
    local state
    app, state = open_with_result(grid_rows(6, 2), grid_columns(2))
    results.render(state)
    vim.api.nvim_win_set_cursor(state.layout.wins.results, { 5, 0 })
    results.render(state)
    eq(vim.api.nvim_win_get_cursor(state.layout.wins.results)[1], 5)
  end)

  it('pulls the cursor back onto the page when a redraw shortens it', function()
    local state
    app, state = open_with_result(grid_rows(8, 2), grid_columns(2))
    results.render(state)
    vim.api.nvim_win_set_cursor(state.layout.wins.results, { 9, 0 })
    state.grid.result = { columns = grid_columns(2), rows = grid_rows(2, 2), malformed = 0 }
    results.render(state)
    eq(vim.api.nvim_win_get_cursor(state.layout.wins.results)[1], 4)
  end)

  it('names the key that connects when there is no session', function()
    local state
    app, state = open_with_result({}, {})
    state.grid.result = nil
    state.grid.source = nil
    results.render(state)
    eq(table.concat(lines(state), '\n'):find('<leader>dc', 1, true) ~= nil, true)
  end)

  it('follows a remap in the hint rather than printing the default key', function()
    local state
    app, state = open_with_result({}, {}, { keymaps = { global = { connections = '<F5>' } } })
    state.grid.result = nil
    state.grid.source = nil
    results.render(state)
    local text = table.concat(lines(state), '\n')
    eq(text:find('<F5>', 1, true) ~= nil, true)
    eq(text:find('<leader>dc', 1, true), nil)
  end)

  it('shows a failed query as one heading and readable detail', function()
    local state
    app, state = open_with_result({}, {})
    state.grid.result = nil
    state.grid.error = 'near "SELCT": syntax error'
    results.render(state)
    local text = table.concat(lines(state), '\n')
    eq(text:find('query failed', 1, true) ~= nil, true)
    eq(text:find('syntax error', 1, true) ~= nil, true)
  end)
end)
