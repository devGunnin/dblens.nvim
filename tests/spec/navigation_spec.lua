--- Navigating a result: following a foreign key, filtering from a cell, jumping to a page, and
--- searching what is loaded.
---
--- The security-relevant one is filter-from-cell. The predicate is GENERATED from a cell value
--- the database handed us, and a value holding a quote, a `;` or a `--` must reach the server as
--- DATA. These cases build the statement that would actually be sent and prove it is still one
--- statement saying what it was meant to say.
local h = require('helpers')

local common = require('dblens.adapters.common')
local fk = require('dblens.fk')
local search = require('dblens.search')
local sqlmod = require('dblens.sql')

local eq, neq = h.eq, h.neq

local DIALECT = sqlmod.dialects.sqlite

local function scratch_options(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
    -- Opening with no connections would otherwise scan the machine the suite runs on.
    discovery = { auto = false },
  }, extra or {})
end

local function open_with_session(session_mod, extra)
  local app = require('dblens.app')
  require('dblens.config').setup(scratch_options(extra))
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.session = h.fake_session(session_mod, {}, scratch_options(extra))
  return app, state
end

-- ---------------------------------------------------------------------------

describe('fk: reading what a column references', function()
  it('reads the `table.column` shape five adapters emit', function()
    eq(fk.targets('users.id', 'user_id'), {
      { table = 'users', column = 'id', composite = false },
    })
  end)

  it(
    'takes the table name up to the LAST dot, so a dotted name is not split in the middle',
    function()
      eq(fk.targets('my.table.id', 'x')[1].table, 'my.table')
    end
  )

  it('reports no target column when the metadata names none', function()
    -- sqlite's pragma leaves `to` NULL for a reference to the implicit primary key.
    eq(fk.targets('users.', 'user_id'), { { table = 'users', column = nil, composite = false } })
  end)

  it('reads every reference when a column carries more than one', function()
    local targets = fk.targets('users.id, teams.id', 'owner')
    eq(#targets, 2)
    eq(targets[1].table, 'users')
    eq(targets[2].table, 'teams')
  end)

  it('reads duckdb constraint text, pairing the source column with its own target', function()
    local text = 'FOREIGN KEY (tenant_id, user_id) REFERENCES users(tenant_id, id)'
    eq(fk.targets(text, 'user_id'), {
      { table = 'users', column = 'id', composite = true },
    })
    eq(fk.targets(text, 'tenant_id')[1].column, 'tenant_id')
  end)

  it('reads several duckdb constraint texts joined into one field', function()
    local text = 'FOREIGN KEY (a) REFERENCES t(x), FOREIGN KEY (a) REFERENCES u(y)'
    local targets = fk.targets(text, 'a')
    eq(#targets, 2)
    eq(targets[1], { table = 't', column = 'x', composite = false })
    eq(targets[2], { table = 'u', column = 'y', composite = false })
  end)

  it('unquotes a delimited name rather than following one that does not exist', function()
    eq(fk.targets('FOREIGN KEY ("a") REFERENCES "my tbl"("id")', 'a')[1], {
      table = 'my tbl',
      column = 'id',
      composite = false,
    })
  end)

  it('reports nothing rather than guessing when there is no usable metadata', function()
    eq(fk.targets(nil, 'x'), {})
    eq(fk.targets('', 'x'), {})
    eq(fk.targets('CHECK (a > 0)', 'a'), {})
  end)
end)

describe('fk: resolving a target against the loaded schema', function()
  local catalog_mod = require('dblens.catalog')

  local function catalog_with(relations)
    local catalog = catalog_mod.new(true)
    catalog:set_schemas({ 'public', 'staging' })
    for schema, list in pairs(relations) do
      catalog:set_relations(schema, list)
    end
    return catalog
  end

  it('prefers the referencing table own schema, because a name repeats across them', function()
    local catalog = catalog_with({
      public = { { schema = 'public', name = 'users', kind = 'table' } },
      staging = { { schema = 'staging', name = 'users', kind = 'table' } },
    })
    local from = { schema = 'staging', name = 'orders', kind = 'table' }
    eq(fk.resolve(catalog, from, 'users').schema, 'staging')
  end)

  it('falls back to another schema rather than refusing to navigate', function()
    local catalog = catalog_with({
      public = { { schema = 'public', name = 'users', kind = 'table' } },
      staging = {},
    })
    local from = { schema = 'staging', name = 'orders', kind = 'table' }
    eq(fk.resolve(catalog, from, 'users').schema, 'public')
  end)

  it('reports nothing for a table that is not loaded', function()
    eq(fk.resolve(catalog_with({ public = {} }), { name = 'orders' }, 'users'), nil)
  end)
end)

-- ---------------------------------------------------------------------------

describe('filter from a cell: the value is data, never syntax', function()
  --- The statement the grid would actually send with this predicate applied.
  local function page_with(predicate)
    return common.page(
      { name = 't', kind = 'table' },
      { limit = 100, offset = 0, where = predicate },
      DIALECT
    )
  end

  it('quotes the value instead of concatenating it', function()
    local predicate = common.cell_predicate('name', "O'Brien", '=', DIALECT)
    eq(predicate, [["name" = 'O''Brien']])
  end)

  it('leaves a statement-stacking value as one statement that compares a string', function()
    local hostile = "x'; DROP TABLE t; --"
    local predicate, err = common.cell_predicate('name', hostile, '=', DIALECT)
    eq(err, nil)
    local statement = page_with(predicate)

    eq(#sqlmod.split(statement, DIALECT), 1, {
      fail_reason = 'the cell value stacked a second statement: ' .. statement,
    })
    -- The whole payload survives, escaped, as one literal - it was not stripped or mangled.
    eq(statement:find("'x''; DROP TABLE t; --'", 1, true) ~= nil, true, {
      fail_reason = statement,
    })
    -- The DROP and the `--` are inside the literal, so neither is syntax: the statement is still
    -- a SELECT and it still carries its own paging.
    eq(sqlmod.classify(statement, DIALECT).write, false, { fail_reason = statement })
    eq(sqlmod.classify(statement, DIALECT).verb, 'SELECT')
    eq(statement:find('LIMIT 100 OFFSET 0', 1, true) ~= nil, true, { fail_reason = statement })
  end)

  it('keeps a comment marker inside the literal, where it cannot comment out the paging', function()
    local predicate = common.cell_predicate('c', '-- /* not a comment', '=', DIALECT)
    local statement = page_with(predicate)
    eq(statement:find('LIMIT 100 OFFSET 0', 1, true) ~= nil, true, { fail_reason = statement })
    eq(common.check_predicate(predicate, DIALECT), nil)
  end)

  it('compares a NULL cell with IS NULL, and its negation with IS NOT NULL', function()
    eq(common.cell_predicate('c', h.NULL, '=', DIALECT), '"c" IS NULL')
    eq(common.cell_predicate('c', h.NULL, '<>', DIALECT), '"c" IS NOT NULL')
    eq(common.cell_predicate('c', nil, '=', DIALECT), '"c" IS NULL')
  end)

  it('negates with the standard operator', function()
    eq(common.cell_predicate('c', '1', '<>', DIALECT), [["c" <> '1']])
  end)

  it('quotes an identifier that would otherwise break out of its own position', function()
    eq(common.cell_predicate('a" OR 1=1 --', '1', '=', DIALECT), [["a"" OR 1=1 --" = '1']])
  end)

  it('refuses a value it cannot express, instead of sending an unprovable predicate', function()
    -- A backslash means different things depending on a server setting, so the filter vetting
    -- refuses it; saying so beats generating a predicate the assertion would then reject.
    local predicate, err = common.cell_predicate('c', 'a\\b', '=', DIALECT)
    eq(predicate, nil)
    eq(type(err) == 'string' and err:find('cannot filter', 1, true) ~= nil, true)

    local nul_predicate, nul_err = common.cell_predicate('c', 'a\0b', '=', DIALECT)
    eq(nul_predicate, nil)
    eq(type(nul_err) == 'string' and nul_err:find('NUL', 1, true) ~= nil, true)
  end)

  it('refuses an operator it does not know', function()
    h.expect_error(function()
      common.cell_predicate('c', '1', 'LIKE', DIALECT)
    end, 'compare_where')
  end)
end)

-- ---------------------------------------------------------------------------

describe('search: finding a value the grid clipped', function()
  local long = string.rep('x', 200) .. 'needle' .. string.rep('y', 200)

  local function result()
    return {
      columns = { 'id', 'note' },
      rows = {
        { '1', long },
        { '2', h.NULL },
        { '3', 'NEEDLE in caps' },
      },
      malformed = 0,
    }
  end

  it('matches the underlying value, not the 40-column text the grid draws', function()
    local matches = search.find(result(), 'needle')
    eq(#matches, 2)
    eq(matches[1], { row = 1, column = 2 })
    eq(matches[2], { row = 3, column = 2 })
  end)

  it('is case-insensitive', function()
    eq(#search.find(result(), 'NEEDLE'), 2)
  end)

  it('matches plainly, so a term with magic characters means those characters', function()
    local rows = { columns = { 'c' }, rows = { { 'a.b' }, { 'axb' } }, malformed = 0 }
    eq(search.find(rows, 'a.b'), { { row = 1, column = 1 } })
  end)

  it('skips NULL rather than matching the word the grid prints for it', function()
    eq(search.find(result(), 'NULL'), {})
  end)

  it('reports a key per match, for the renderer to highlight', function()
    local _, keys = search.find(result(), 'needle')
    eq(keys, { ['1:2'] = true, ['3:2'] = true })
  end)

  it('wraps at either end', function()
    eq(search.step(3, 3, 1), 1)
    eq(search.step(3, 1, -1), 3)
    eq(search.step(1, 1, 1), 1)
  end)
end)

describe('render: a match is highlighted over the type colour', function()
  local grid = require('dblens.render.grid')

  --- The highlight each data row got, in row order.
  local function row_highlights(input)
    local output = grid.render(vim.tbl_extend('force', {
      columns = { 'id' },
      rows = { { '1' }, { '2' } },
      max_col_width = 40,
      null_display = 'NULL',
      separator = '|',
      truncation = '~',
    }, input))
    local out = {}
    for _, mark in ipairs(output.marks) do
      -- Lines 0 and 1 are the header and its rule.
      if mark.line >= 2 then
        out[mark.line - 1] = mark.hl
      end
    end
    return out
  end

  it('paints a matching cell with DbLensMatch and leaves the rest to their type colour', function()
    eq(row_highlights({}), { 'DbLensNumber', 'DbLensNumber' })
    eq(row_highlights({ search = { ['2:1'] = true } }), { 'DbLensNumber', 'DbLensMatch' })
  end)

  it('shows a match over a queued edit, which is the mark the user just asked for', function()
    eq(
      row_highlights({ dirty = { ['1:1'] = true }, search = { ['1:1'] = true } }),
      { 'DbLensMatch', 'DbLensNumber' }
    )
  end)
end)

-- ---------------------------------------------------------------------------

--- A generated predicate is correctly quoted, so the value is data — but a locked run must be
--- PROVABLY one statement, and that proof is a byte scan that does not read quoting. So a cell
--- holding a `;` is refused while LOCKED and usable once unlocked, and the refusal has to name
--- the value rather than leaving the gate to complain about multiple statements.
describe('app: filtering on a value that holds a `;`', function()
  local RELATION = { name = 't', kind = 'table' }

  local function browsing(session_mod, spec)
    local options = scratch_options()
    local app = require('dblens.app')
    require('dblens.config').setup(options)
    app.open()
    local state = app.state()
    assert(state, 'app.open left no state')
    state.session = h.fake_session(session_mod, spec, options)
    state.grid.source = { kind = 'relation', relation = RELATION, label = 't' }
    state.grid.result = { columns = { 'note' }, rows = { { 'a;b' } }, malformed = 0 }
    return app, state
  end

  it('is refused, unsent, while the connection is LOCKED', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod, { read_only = true })
      app.filter_by_cell({ row = 1, column = 1, name = 'note', value = 'a;b' }, '=')
      eq(#calls, 0, { fail_reason = 'an unprovable run was sent to the client' })
      eq(state.grid.filter, nil)
      app.close()
    end)
  end)

  it('is applied, quoted, once the connection is open for editing', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod, { read_only = false })
      app.filter_by_cell({ row = 1, column = 1, name = 'note', value = 'a;b' }, '=')
      eq(state.grid.filter, [["note" = 'a;b']])
      eq(calls[1].stdin:find([[WHERE "note" = 'a;b']], 1, true) ~= nil, true, {
        fail_reason = calls[1].stdin,
      })
      app.close()
    end)
  end)
end)

describe('app: following a foreign key', function()
  local ORDERS = { name = 'orders', kind = 'table' }
  local CUSTOMERS = { name = 'customers', kind = 'table' }

  --- A catalog with both tables fully loaded, so `load_relation_details` makes no round trip and
  --- every client call in the case belongs to the navigation itself.
  local function seed(state, fk_text)
    local catalog = state.session.catalog
    catalog:set_relations(nil, { ORDERS, CUSTOMERS })
    for _, relation in ipairs({ ORDERS, CUSTOMERS }) do
      catalog:set_part(relation, 'indexes', {})
      catalog:set_part(relation, 'constraints', {})
    end
    catalog:set_part(ORDERS, 'columns', {
      { name = 'id', type = 'int', notnull = true, pk = 1 },
      { name = 'customer_id', type = 'int', notnull = false, pk = 0, fk = fk_text },
    })
    catalog:set_part(CUSTOMERS, 'columns', {
      { name = 'id', type = 'int', notnull = true, pk = 1 },
    })
    state.grid.source = { kind = 'relation', relation = ORDERS, label = 'orders' }
    state.grid.result =
      { columns = { 'id', 'customer_id' }, rows = { { '1', '7' } }, malformed = 0 }
  end

  local function page_calls(calls)
    local out = {}
    for _, call in ipairs(calls) do
      if call.stdin:find('SELECT * FROM', 1, true) then
        out[#out + 1] = call.stdin
      end
    end
    return out
  end

  it('opens the referenced table filtered to the referenced row, and says where from', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      seed(state, 'customers.id')

      app.follow_fk({ row = 1, column = 2, name = 'customer_id', value = '7' })

      eq(page_calls(calls), { [[SELECT * FROM "customers" WHERE "id" = '7' LIMIT 100 OFFSET 0]] })
      eq(state.grid.source.relation.name, 'customers')
      eq(state.grid.source.origin, 'orders.customer_id')
      eq(state.grid.filter, [["id" = '7']])
      app.close()
    end)
  end)

  it('quotes a hostile key value rather than splicing it', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      seed(state, 'customers.id')

      app.follow_fk({ row = 1, column = 2, name = 'customer_id', value = "7' OR '1'='1" })

      local sent = page_calls(calls)[1]
      eq(sent ~= nil, true, { fail_reason = 'no page was fetched' })
      eq(sqlmod.single_statement_problem(sent), nil, { fail_reason = sent })
      eq(sent:find([['7'' OR ''1''=''1']], 1, true) ~= nil, true, { fail_reason = sent })
      app.close()
    end)
  end)

  it('assumes the primary key when the metadata names no target column', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      seed(state, 'customers.')

      app.follow_fk({ row = 1, column = 2, name = 'customer_id', value = '7' })

      eq(page_calls(calls), { [[SELECT * FROM "customers" WHERE "id" = '7' LIMIT 100 OFFSET 0]] })
      app.close()
    end)
  end)

  it('does nothing but explain itself on a NULL cell', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      seed(state, 'customers.id')

      app.follow_fk({ row = 1, column = 2, name = 'customer_id', value = h.NULL })

      eq(page_calls(calls), {}, { fail_reason = 'a NULL cell still queried the target' })
      eq(state.grid.source.relation.name, 'orders', { fail_reason = 'the grid moved anyway' })
      app.close()
    end)
  end)

  it('does nothing on a column with no foreign key', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      seed(state, 'customers.id')

      app.follow_fk({ row = 1, column = 1, name = 'id', value = '1' })

      eq(page_calls(calls), {})
      app.close()
    end)
  end)

  it('refuses to navigate to a table that is not loaded, rather than querying a guess', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      seed(state, 'nowhere.id')

      app.follow_fk({ row = 1, column = 2, name = 'customer_id', value = '7' })

      eq(page_calls(calls), {})
      app.close()
    end)
  end)

  it('needs a table: a query result has no column metadata to follow', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      seed(state, 'customers.id')
      state.grid.source = { kind = 'query', sql = 'select 1', label = 'query' }

      app.follow_fk({ row = 1, column = 2, name = 'customer_id', value = '7' })

      eq(page_calls(calls), {})
      app.close()
    end)
  end)
end)

-- ---------------------------------------------------------------------------

describe('app: jumping to a page', function()
  local RELATION = { name = 't', kind = 'table' }

  local function browsing(session_mod, total)
    local app, state = open_with_session(session_mod, { page_size = 10 })
    state.grid.source = { kind = 'relation', relation = RELATION, label = 't' }
    state.grid.result = { columns = { 'id' }, rows = { { '1' } }, malformed = 0 }
    state.grid.paging = require('dblens.paging').new(10, total)
    return app, state
  end

  it('fetches the page asked for, at the right offset', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod, 95)
      app.goto_page(4)
      eq(state.grid.paging.page, 4)
      eq(calls[#calls].stdin:find('LIMIT 10 OFFSET 30', 1, true) ~= nil, true, {
        fail_reason = calls[#calls].stdin,
      })
      app.close()
    end)
  end)

  it('clamps past the end instead of asking the server for a page that cannot exist', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = browsing(session_mod, 95)
      app.goto_page(9999)
      eq(state.grid.paging.page, 10, { fail_reason = '95 rows of 10 is 10 pages' })
      app.close()
    end)
  end)

  it('refuses page 0 and below', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod, 95)
      local before = #calls
      app.goto_page(0)
      eq(#calls, before, { fail_reason = 'page 0 reached the server' })
      eq(state.grid.paging.page, 1)
      app.close()
    end)
  end)

  it('goes to the first and the last page', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = browsing(session_mod, 95)
      app.page_edge('last')
      eq(state.grid.paging.page, 10)
      app.page_edge('first')
      eq(state.grid.paging.page, 1)
      app.close()
    end)
  end)

  it('says the last page is unknown rather than guessing one, with no count', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod, nil)
      local before = #calls
      app.page_edge('last')
      eq(state.grid.paging.page, 1)
      eq(#calls, before, { fail_reason = 'a guessed last page was fetched' })
      app.close()
    end)
  end)

  it('needs a table, like every other pager action', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod, 95)
      state.grid.source = { kind = 'query', sql = 'select 1', label = 'query' }
      local before = #calls
      app.goto_page(3)
      eq(#calls, before)
      eq(state.grid.paging.page, 1)
      app.close()
    end)
  end)
end)

-- ---------------------------------------------------------------------------

describe('app: searching the loaded result', function()
  local function with_result(session_mod)
    local app, state = open_with_session(session_mod)
    state.grid.source = { kind = 'query', sql = 'select', label = 'query' }
    state.grid.result = {
      columns = { 'id', 'note' },
      rows = { { '1', 'alpha' }, { '2', 'beta' }, { '3', 'alphabet' } },
      malformed = 0,
    }
    return app, state
  end

  it('records the matches and starts on the first', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = with_result(session_mod)
      eq(app.search_result('alpha'), { row = 1, column = 2 })
      eq(#state.grid.search.matches, 2)
      eq(state.grid.search.index, 1)
      eq(state.grid.search.keys, { ['1:2'] = true, ['3:2'] = true })
      app.close()
    end)
  end)

  it('steps forward and back, wrapping', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app = with_result(session_mod)
      app.search_result('alpha')
      eq(app.step_match(1), { row = 3, column = 2 })
      eq(app.step_match(1), { row = 1, column = 2 })
      eq(app.step_match(-1), { row = 3, column = 2 })
      app.close()
    end)
  end)

  it('keeps no stale highlight when nothing matches', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = with_result(session_mod)
      app.search_result('alpha')
      eq(app.search_result('zzz'), nil)
      eq(state.grid.search, nil)
      app.close()
    end)
  end)

  it('drops the matches when a new result replaces the rows they point at', function()
    h.with_fake_exec(function(call)
      if call.stdin:find('count(*)', 1, true) then
        return { stdout = h.wire({ h.record('n'), h.record('1') }) }
      end
      return { stdout = h.wire({ h.record('id'), h.record('9') }) }
    end, function(session_mod)
      local app, state = with_result(session_mod)
      app.search_result('alpha')
      neq(state.grid.search, nil)

      state.grid.source =
        { kind = 'relation', relation = { name = 't', kind = 'table' }, label = 't' }
      app.fetch_page()
      eq(state.grid.search, nil, { fail_reason = 'matches survived the rows they indexed' })
      app.close()
    end)
  end)

  it('puts the cursor on the match, which is how a clipped cell is reached at all', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = with_result(session_mod)
      local results = require('dblens.ui.results')
      results.render(state)

      results.focus_match(state, app.search_result('alphabet'))

      local cursor = vim.api.nvim_win_get_cursor(state.layout.wins.results)
      -- Row 3 of the result, under the two header lines.
      eq(cursor[1], 3 + state.grid.header_lines)
      local line =
        vim.api.nvim_buf_get_lines(state.layout.bufs.results, cursor[1] - 1, cursor[1], false)[1]
      eq(line:sub(cursor[2] + 1, cursor[2] + 8), 'alphabet', { fail_reason = line })
      app.close()
    end)
  end)

  it('says there is nothing to search rather than raising on an empty grid', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      state.grid.result = nil
      eq(app.search_result('x'), nil)
      eq(app.step_match(1), nil)
      app.close()
    end)
  end)
end)

-- ---------------------------------------------------------------------------

describe('picker: running a stored statement instead of pasting it', function()
  it('sends it through the gate, so a write on a LOCKED connection is refused', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      state.session = h.fake_session(session_mod, { read_only = true }, scratch_options())

      -- What `<C-r>` in the history picker does with the entry it is holding.
      app.run_sql('DELETE FROM t', { label = 'history' })

      eq(#calls, 0, { fail_reason = 'a stored DELETE ran on a locked connection' })
      app.close()
    end)
  end)

  it('offers the run action only where there is one, and names it in the footer', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      local picker = require('dblens.ui.picker')

      local plain = picker.select(state, {
        title = 'plain',
        items = { { text = 'a', value = 'a' } },
        on_choose = function() end,
      })
      local footer = vim.api.nvim_win_get_config(plain.prompt_win).footer[1][1]
      eq(footer:find('<C-r>', 1, true), nil, { fail_reason = footer })
      plain:close()

      local runnable = picker.select(state, {
        title = 'runnable',
        items = { { text = 'a', value = 'a' } },
        on_choose = function() end,
        on_alt = function() end,
        choose_hint = 'to editor',
        alt_hint = 'run',
      })
      footer = vim.api.nvim_win_get_config(runnable.prompt_win).footer[1][1]
      eq(footer:find('<C-r> run', 1, true) ~= nil, true, { fail_reason = footer })
      eq(footer:find('<CR> to editor', 1, true) ~= nil, true, { fail_reason = footer })
      runnable:close()
      app.close()
    end)
  end)
end)
