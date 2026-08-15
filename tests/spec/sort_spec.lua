--- Grid sorting: the cycle, the multi-column order, and what the header shows for it.
---
--- Every one of these is a SERVER-side ORDER BY, so the assertions are on the statement the
--- adapter built. Two properties matter beyond "it sorted": the column name is quoted by the
--- dialect rather than concatenated (a column called `select` is a name, not a keyword), and a
--- sort change re-reads from page 1 — the rows that come first have changed, so the page the user
--- was on no longer names the same ones.
local h = require('helpers')

local common = require('dblens.adapters.common')
local grid = require('dblens.render.grid')
local sqlmod = require('dblens.sql')

local eq = h.eq

local DIALECT = sqlmod.dialects.sqlite
local RELATION = { name = 'orders', kind = 'table' }

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

--- A UI open on a browsed table, with a fake client behind it.
---@return table app, table state
local function open_on_table(session_mod, extra)
  local app = require('dblens.app')
  local options = scratch_options(extra)
  require('dblens.config').setup(options)
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.session = h.fake_session(session_mod, {}, options)
  state.grid.source = { kind = 'relation', relation = RELATION, label = 'orders' }
  state.grid.result = { columns = { 'id', 'name' }, rows = { { '1', 'a' } }, malformed = 0 }
  return app, state
end

--- Client stdout for the page statement the grid built, against a table of `total` rows.
local function wire_page(stdin, total)
  local limit = tonumber(stdin:match('LIMIT (%d+)'))
  local offset = tonumber(stdin:match('OFFSET (%d+)'))
  assert(limit and offset, 'the page statement carried no LIMIT/OFFSET: ' .. stdin)
  local records = { h.record('id', 'name') }
  for id = offset + 1, math.min(offset + limit, total) do
    records[#records + 1] = h.record(tostring(id), 'name ' .. id)
  end
  return h.wire(records)
end

--- Drive `fn` with the page statements the grid asked the client for.
---@param fn fun(app: table, state: table, sent: string[])
local function with_pages(fn, extra)
  local sent = {}
  h.with_fake_exec(function(call)
    if call.stdin and call.stdin:find('SELECT * FROM', 1, true) then
      sent[#sent + 1] = call.stdin
      return { stdout = wire_page(call.stdin, 12) }
    end
    return {}
  end, function(session_mod)
    local app, state = open_on_table(session_mod, extra)
    fn(app, state, sent)
    app.close()
  end)
end

local function last(sent)
  assert(#sent > 0, 'the grid never queried a page')
  return sent[#sent]
end

describe('sort: one column, cycled', function()
  it('goes ascending, then descending, then unsorted', function()
    with_pages(function(app, state, sent)
      app.sort_by('name')
      eq(last(sent):find('ORDER BY "name" ASC', 1, true) ~= nil, true, { fail_reason = last(sent) })
      app.sort_by('name')
      eq(
        last(sent):find('ORDER BY "name" DESC', 1, true) ~= nil,
        true,
        { fail_reason = last(sent) }
      )
      app.sort_by('name')
      eq(last(sent):find('ORDER BY', 1, true), nil, { fail_reason = last(sent) })
      eq(state.grid.sort, nil)
    end)
  end)

  it('replaces the whole sort, so a second column is not left ordering underneath', function()
    with_pages(function(app, state)
      app.sort_by('name')
      app.add_sort('id')
      eq(#state.grid.sort, 2)
      app.sort_by('id')
      eq(state.grid.sort, { { column = 'id', desc = false } })
    end)
  end)

  it('re-reads from the first page: the rows that come first have changed', function()
    with_pages(function(app, state, sent)
      state.grid.paging.page = 4
      app.sort_by('name')
      eq(state.grid.paging.page, 1)
      eq(last(sent):find('OFFSET 0', 1, true) ~= nil, true, { fail_reason = last(sent) })
    end, { page_size = 10 })
  end)

  it("needs a table: a query result is whatever the user's own statement returned", function()
    with_pages(function(app, state, sent)
      state.grid.source = { kind = 'query', label = 'query' }
      app.sort_by('name')
      eq(#sent, 0, { fail_reason = 'a query result was re-queried as a sorted table' })
      eq(state.grid.sort, nil)
    end)
  end)

  --- Clearing is not "add a sort": a query result has nothing to clear, so `gs` there should say
  --- the rows are unsorted, not repeat the "needs a table" message meant for `s`/`S`.
  it(
    'clearing on a query result says the rows are not sorted, not that sorting needs a table',
    function()
      with_pages(function(app, state)
        state.grid.source = { kind = 'query', label = 'query' }
        local said = {}
        local notify = vim.notify
        vim.notify = function(message)
          said[#said + 1] = message
        end
        app.clear_sort()
        vim.notify = notify
        eq(#said, 1)
        eq(said[1]:find('the rows are not sorted', 1, true) ~= nil, true, { fail_reason = said[1] })
      end)
    end
  )
end)

describe('sort: several columns, in the order they were chosen', function()
  it('appends a key, and orders by every one of them', function()
    with_pages(function(app, state, sent)
      app.sort_by('name')
      app.add_sort('id')
      eq(state.grid.sort, { { column = 'name', desc = false }, { column = 'id', desc = false } })
      eq(
        last(sent):find('ORDER BY "name" ASC, "id" ASC', 1, true) ~= nil,
        true,
        { fail_reason = last(sent) }
      )
    end)
  end)

  it('cycles a key already in the sort without moving the ones around it', function()
    with_pages(function(app, state, sent)
      app.sort_by('name')
      app.add_sort('id')
      app.add_sort('name')
      eq(
        last(sent):find('ORDER BY "name" DESC, "id" ASC', 1, true) ~= nil,
        true,
        { fail_reason = last(sent) }
      )
      -- Third press drops that key, leaving the rest of the order intact.
      app.add_sort('name')
      eq(state.grid.sort, { { column = 'id', desc = false } })
    end)
  end)

  it('clears every key at once', function()
    with_pages(function(app, state, sent)
      app.sort_by('name')
      app.add_sort('id')
      app.clear_sort()
      eq(state.grid.sort, nil)
      eq(last(sent):find('ORDER BY', 1, true), nil, { fail_reason = last(sent) })
    end)
  end)

  it('composes with the filter and with paging, in one statement', function()
    with_pages(function(app, state, sent)
      state.grid.filter = "name > 'a'"
      app.sort_by('name')
      app.add_sort('id')
      app.page(1)
      local statement = last(sent)
      eq(statement:find("WHERE name > 'a'", 1, true) ~= nil, true, { fail_reason = statement })
      eq(
        statement:find('ORDER BY "name" ASC, "id" ASC LIMIT 5 OFFSET 5', 1, true) ~= nil,
        true,
        { fail_reason = statement }
      )
    end, { page_size = 5 })
  end)
end)

describe('sort: the column name is a name, never a fragment of the statement', function()
  it('quotes a keyword, a spaced name, and one carrying the quote character', function()
    eq(
      common.page({ name = 't' }, {
        limit = 10,
        offset = 0,
        order_by = {
          { column = 'select' },
          { column = 'weird name', desc = true },
          { column = 'a"b' },
        },
      }, DIALECT),
      'SELECT * FROM "t" ORDER BY "select" ASC, "weird name" DESC, "a""b" ASC LIMIT 10 OFFSET 0'
    )
  end)

  it('escapes a name that tries to close its own quote and append a key', function()
    local keys = common.order_keys({ { column = 'id" DESC, (SELECT 1) --' } }, nil, DIALECT)
    eq(keys, { '"id"" DESC, (SELECT 1) --" ASC' })
    eq(#keys, 1, { fail_reason = 'the name became a second ORDER BY key' })
  end)

  it('refuses a nameless key, and the same column twice', function()
    h.expect_error(function()
      common.order_keys({ { column = '' } }, nil, DIALECT)
    end, 'a sort key needs a column')
    h.expect_error(function()
      common.order_keys({ { column = 'id' }, { column = 'id', desc = true } }, nil, DIALECT)
    end, 'two sort keys')
  end)

  it('appends the tiebreak only for columns the sort does not already cover', function()
    eq(
      common.order_keys({ { column = 'name' } }, { 'id', 'name' }, DIALECT),
      { '"name" ASC', '"id" ASC' }
    )
    eq(common.order_keys(nil, nil, DIALECT), {})
  end)
end)

describe('sort: what the header shows', function()
  local function render(sort, glyphs)
    return grid.render({
      columns = { 'id', 'name' },
      rows = { { '1', 'a' } },
      max_col_width = 40,
      null_display = 'NULL',
      separator = '|',
      truncation = '~',
      sort = sort,
      sort_glyphs = glyphs,
    })
  end

  it('marks a single key with an arrow and no position', function()
    local out = render({ { column = 'name', desc = true } }, { asc = '▲', desc = '▼' })
    eq(out.lines[1]:find('name ▼', 1, true) ~= nil, true, { fail_reason = out.lines[1] })
    eq(out.lines[1]:find('▼1', 1, true), nil, { fail_reason = 'a single sort key is numbered' })
  end)

  it('numbers the keys when there is more than one, in sort order', function()
    local out = render(
      { { column = 'name', desc = true }, { column = 'id' } },
      { asc = '▲', desc = '▼' }
    )
    eq(out.lines[1]:find('name ▼1', 1, true) ~= nil, true, { fail_reason = out.lines[1] })
    eq(out.lines[1]:find('id ▲2', 1, true) ~= nil, true, { fail_reason = out.lines[1] })
  end)

  it('falls back to ASCII arrows for a terminal with no glyphs', function()
    local plain = require('dblens.ui.icons').get(false)
    local out = render({ { column = 'id' } }, { asc = plain.sort_asc, desc = plain.sort_desc })
    eq(out.lines[1]:find('id ^', 1, true) ~= nil, true, { fail_reason = out.lines[1] })
  end)

  it('widens the column for the marker, so the grid stays aligned', function()
    local plain = render(nil, nil)
    local sorted = render({ { column = 'id' } }, { asc = '▲', desc = '▼' })
    eq(
      sorted.widths[1] > plain.widths[1],
      true,
      { fail_reason = 'the arrow overflowed the column' }
    )
    eq(vim.fn.strdisplaywidth(sorted.lines[1]), vim.fn.strdisplaywidth(sorted.lines[3]), {
      fail_reason = 'the header and a data row are no longer the same width',
    })
    -- Both key columns are highlighted, on top of the header's own mark.
    local out = render({ { column = 'id' }, { column = 'name' } }, { asc = '▲', desc = '▼' })
    local keys = 0
    for _, mark in ipairs(out.marks) do
      keys = keys + (mark.hl == 'DbLensSortKey' and 1 or 0)
    end
    eq(keys, 2)
  end)
end)

--- sqlite, live. The generated ORDER BY run by a real client against a real table: the proof that
--- a multi-key order is one the ENGINE applies, and that a column named `select`, or one carrying
--- the quote character itself, is a name to it and not syntax.
describe('sqlite, live: the engine applies the order dblens built', function()
  local MiniTest = require('mini.test')
  local adapter = assert(require('dblens.adapters').get('sqlite'))
  local RELATION_LIVE = { name = 'orders', kind = 'table' }
  local live, db = nil, nil

  local function run(statement)
    local command =
      adapter.command({ name = 'live', kind = 'sqlite', path = db }, nil, 'records', live.clients)
    return vim.system(command.argv, { env = command.env, stdin = statement }):wait(30000)
  end

  before_each(function()
    live = h.live_file_client('sqlite')
    db = vim.fn.tempname() .. '.db'
  end)

  after_each(function()
    if db then
      vim.fn.delete(db)
    end
  end)

  it('orders by every key, in order, with awkward column names quoted', function()
    if not live then
      MiniTest.add_note('no sqlite3 client; the live sort proof did not run')
      return
    end
    local seeded = run([[
CREATE TABLE orders (id INTEGER PRIMARY KEY, city TEXT, amount INTEGER, "select" TEXT);
INSERT INTO orders VALUES (1,'oslo',30,'a'),(2,'bergen',10,'b'),(3,'oslo',10,'c'),
                          (4,'aalborg',50,'d'),(5,'bergen',40,'e'),(6,'oslo',20,'f');
]])
    h.eq(seeded.code, 0, { fail_reason = tostring(seeded.stderr) })

    local statement = adapter.sql.page(RELATION_LIVE, {
      limit = 10,
      offset = 0,
      order_by = { { column = 'city' }, { column = 'amount', desc = true }, { column = 'select' } },
    })
    eq(
      statement:find('ORDER BY "city" ASC, "amount" DESC, "select" ASC', 1, true) ~= nil,
      true,
      { fail_reason = statement }
    )
    local out = run(statement .. ';')
    eq(out.code, 0, { fail_reason = tostring(out.stderr) })
    local rows = adapter.decode(out.stdout, {}).rows
    local order = {}
    for _, row in ipairs(rows) do
      order[#order + 1] = row[1]
    end
    -- city ascending, then the larger amount first inside each city.
    eq(order, { '4', '5', '2', '1', '6', '3' }, { fail_reason = tostring(out.stdout) })
  end)
end)
