--- The interactive filter builder: the operator menu, the predicates it composes, and what
--- reaches the client.
---
--- Every predicate here is generated from a cell the user pointed at, so the property under test
--- is the same one filter-from-cell has: the VALUE and the COLUMN NAME are quoted for the dialect,
--- never concatenated, and the result is vetted by the predicate allow-list before it is spliced
--- into a statement. A value carrying `'`, `;` or `--` and a column named `select` must come out
--- as data and a name.
local h = require('helpers')

local common = require('dblens.adapters.common')
local filter = require('dblens.filter')
local sqlmod = require('dblens.sql')

local eq = h.eq

local DIALECT = sqlmod.dialects.sqlite
local RELATION = { name = 'orders', kind = 'table' }

--- The predicate, asserting the build was not refused.
local function build(column, op, values, dialect)
  local predicate, problem = filter.build(column, op, values, dialect or DIALECT)
  eq(problem, nil, { fail_reason = ('%s %s: %s'):format(column, op, tostring(problem)) })
  return predicate
end

--- The paged statement the grid would send with this predicate applied.
local function page_with(predicate, dialect)
  return common.page(RELATION, { limit = 50, offset = 0, where = predicate }, dialect or DIALECT)
end

describe('filter builder: each operator builds its own WHERE', function()
  it('compares, ranges and matches', function()
    eq(build('n', '=', { '1' }), [["n" = '1']])
    eq(build('n', '<>', { '1' }), [["n" <> '1']])
    eq(build('n', '>', { '1' }), [["n" > '1']])
    eq(build('n', '>=', { '1' }), [["n" >= '1']])
    eq(build('n', '<', { '1' }), [["n" < '1']])
    eq(build('n', '<=', { '1' }), [["n" <= '1']])
    eq(build('n', 'BETWEEN', { '1', '9' }), [["n" BETWEEN '1' AND '9']])
    eq(build('n', 'IN', { '1', '2', '3' }), [["n" IN ('1', '2', '3')]])
    eq(build('c', 'LIKE', { '%ab%' }), [["c" LIKE '%ab%']])
    eq(build('c', 'NOT LIKE', { '%ab%' }), [["c" NOT LIKE '%ab%']])
    eq(build('c', 'ILIKE', { '%ab%' }, sqlmod.dialects.postgres), [["c" ILIKE E'%ab%']])
    eq(build('c', 'IS NULL', {}), '"c" IS NULL')
    eq(build('c', 'IS NOT NULL', {}), '"c" IS NOT NULL')
  end)

  it('emits `<>` for the menu label `!=`, the spelling every engine takes', function()
    local operators = filter.menu({ type = 'integer' })
    local negation
    for _, operator in ipairs(operators) do
      if operator.label == '!=' then
        negation = operator
      end
    end
    eq(negation ~= nil and negation.id, '<>')
  end)

  it('takes exactly the values its arity names', function()
    h.expect_error(function()
      filter.build('c', 'IS NULL', { 'x' }, DIALECT)
    end, 'takes 0 value')
    h.expect_error(function()
      filter.build('c', 'BETWEEN', { '1' }, DIALECT)
    end, 'takes 2 value')
    h.expect_error(function()
      filter.build('c', 'IN', {}, DIALECT)
    end, 'at least one value')
    h.expect_error(function()
      filter.build('c', 'REGEXP', { 'x' }, DIALECT)
    end, 'unknown operator')
  end)

  it('quotes for the dialect it was handed, not for one of them', function()
    eq(build('n', 'IN', { "o'brien" }, sqlmod.dialects.mysql), [[`n` IN ('o''brien')]])
    eq(build('n', '=', { "o'brien" }, sqlmod.dialects.postgres), [["n" = E'o''brien']])
  end)
end)

describe('filter builder: a hostile value is data, and a hostile column is a name', function()
  local HOSTILE = "x'; DROP TABLE victim; --"

  --- Whatever the operator, the value ends up inside ONE literal in ONE statement that still
  --- carries its own paging.
  local function expect_contained(predicate)
    local statement = page_with(predicate)
    eq(#sqlmod.split(statement, DIALECT), 1, {
      fail_reason = 'the value stacked a second statement: ' .. statement,
    })
    eq(sqlmod.classify(statement, DIALECT).write, false, { fail_reason = statement })
    eq(sqlmod.classify(statement, DIALECT).verb, 'SELECT', { fail_reason = statement })
    eq(statement:find('LIMIT 50 OFFSET 0', 1, true) ~= nil, true, { fail_reason = statement })
  end

  it('escapes the value under every operator that takes one', function()
    for _, case in ipairs({
      { op = '=', values = { HOSTILE } },
      { op = '<>', values = { HOSTILE } },
      { op = '>', values = { HOSTILE } },
      { op = 'LIKE', values = { '%' .. HOSTILE .. '%' } },
      { op = 'NOT LIKE', values = { HOSTILE } },
      { op = 'IN', values = { HOSTILE, 'plain' } },
      { op = 'BETWEEN', values = { HOSTILE, HOSTILE } },
    }) do
      local predicate = build('note', case.op, case.values)
      -- The whole payload survives, escaped, inside the literal - not stripped, not mangled.
      eq(predicate:find("x''; DROP TABLE victim; --", 1, true) ~= nil, true, {
        fail_reason = case.op .. ': ' .. predicate,
      })
      expect_contained(predicate)
    end
  end)

  it('quotes a column name that would otherwise break out of its own position', function()
    eq(build([[a" OR 1=1 --]], '=', { '1' }), [["a"" OR 1=1 --" = '1']])
    expect_contained(build([[a" OR 1=1 --]], 'IS NULL', {}))
  end)

  it('quotes a column named after a keyword, so it stays a name', function()
    eq(build('select', 'IN', { 'a', 'b' }), [["select" IN ('a', 'b')]])
    eq(
      build('select', 'BETWEEN', { 'a', 'b' }, sqlmod.dialects.mysql),
      [[`select` BETWEEN 'a' AND 'b']]
    )
  end)

  it('refuses a NUL byte in the value or the column, with a message not an assertion', function()
    local predicate, problem = filter.build('c', '=', { 'a\0b' }, DIALECT)
    eq(predicate, nil)
    eq(type(problem) == 'string' and problem:find('NUL', 1, true) ~= nil, true, {
      fail_reason = tostring(problem),
    })
    local by_column, column_problem = filter.build('a\0b', 'IS NULL', {}, DIALECT)
    eq(by_column, nil)
    eq(type(column_problem) == 'string' and column_problem:find('NUL', 1, true) ~= nil, true, {
      fail_reason = tostring(column_problem),
    })
  end)

  --- The one value class the allow-list cannot express, refused with a reason rather than sent.
  it('refuses a backslash where it may escape, on every operator', function()
    for _, op in ipairs({ '=', 'LIKE', 'IN', 'BETWEEN' }) do
      local values = op == 'BETWEEN' and { [[C:\]], [[C:\]] } or { [[C:\]] }
      local predicate, problem = filter.build('c', op, values, sqlmod.dialects.mysql)
      eq(predicate, nil, { fail_reason = op .. ' accepted a backslash mysql cannot pin down' })
      eq(problem:find('backslash', 1, true) ~= nil, true, { fail_reason = problem })
    end
    -- And accepted where a backslash is an ordinary byte.
    eq(build('c', '=', { [[C:\]] }, sqlmod.dialects.sqlite), [["c" = 'C:\']])
  end)
end)

describe('filter builder: the menu is ordered for the column', function()
  local function ids(opts)
    local out = {}
    for _, operator in ipairs(filter.menu(opts)) do
      out[#out + 1] = operator.id
    end
    return out
  end

  local function position(list, id)
    for index, entry in ipairs(list) do
      if entry == id then
        return index
      end
    end
    return nil
  end

  it('classifies the types each engine actually reports', function()
    eq(filter.classify('INTEGER'), 'numeric')
    eq(filter.classify('bigint unsigned'), 'numeric')
    eq(filter.classify('numeric(10,2)'), 'numeric')
    eq(filter.classify('double precision'), 'numeric')
    eq(filter.classify('timestamp with time zone'), 'temporal')
    eq(filter.classify('DATETIME'), 'temporal')
    -- `interval` carries `int`, so temporal has to win.
    eq(filter.classify('interval'), 'temporal')
    eq(filter.classify('character varying(20)'), 'text')
    eq(filter.classify('TEXT'), 'text')
    eq(filter.classify('jsonb'), 'text')
    eq(filter.classify('blob'), 'other')
    eq(filter.classify(nil), 'other')
    eq(filter.classify(''), 'other')
  end)

  it('surfaces the range operators on a number and a date', function()
    for _, column_type in ipairs({ 'integer', 'timestamp' }) do
      local order = ids({ type = column_type })
      eq(position(order, 'BETWEEN') < position(order, 'LIKE'), true, { fail_reason = column_type })
      eq(position(order, '>') < position(order, 'IN'), true, { fail_reason = column_type })
    end
  end)

  it('surfaces the pattern operators on text', function()
    local order = ids({ type = 'varchar(20)' })
    eq(position(order, 'LIKE') < position(order, '>'), true)
    eq(position(order, 'LIKE') < position(order, 'BETWEEN'), true)
  end)

  it('puts IS NULL first for a NULL cell, whatever the column type is', function()
    for _, column_type in ipairs({ 'integer', 'text', nil }) do
      local order = ids({ type = column_type, is_null = true })
      eq(
        { order[1], order[2] },
        { 'IS NULL', 'IS NOT NULL' },
        { fail_reason = tostring(column_type) }
      )
    end
    eq(ids({ type = 'text' })[1], '=')
  end)

  it('offers ILIKE only where the engine has the keyword', function()
    eq(h.has(ids({ type = 'text', ilike = true }), 'ILIKE'), true)
    eq(h.has(ids({ type = 'text', ilike = true }), 'NOT ILIKE'), true)
    eq(h.has(ids({ type = 'text' }), 'ILIKE'), false)
    eq(h.has(ids({ type = 'text' }), 'NOT ILIKE'), false)
  end)

  it('is a re-ordering, not a subset: every operator is reachable', function()
    eq(#ids({ type = 'integer', ilike = true }), #filter.OPERATORS)
    eq(#ids({ type = 'text', ilike = true, is_null = true }), #filter.OPERATORS)
  end)

  --- Every adapter has to answer the capability question, or the menu silently drops ILIKE where
  --- the engine does have it.
  it('every adapter declares whether it has ILIKE', function()
    local adapters = require('dblens.adapters')
    local EXPECTED = {
      sqlite = false,
      postgres = true,
      mysql = false,
      mariadb = false,
      duckdb = true,
      mssql = false,
    }
    for kind, expected in pairs(EXPECTED) do
      eq(assert(adapters.get(kind)).caps.ilike, expected, { fail_reason = kind })
    end
  end)
end)

describe('filter builder: parsing what the prompts collect', function()
  it('splits an IN list on commas and trims each entry', function()
    eq(filter.split_list('a, b ,c'), { 'a', 'b', 'c' })
    eq(filter.split_list(' 1 '), { '1' })
    -- A trailing comma is forgiving rather than an empty literal.
    eq(filter.split_list('a,b,'), { 'a', 'b' })
  end)

  it('refuses a list with nothing in it', function()
    local values, problem = filter.split_list('  ,, ')
    eq(values, nil)
    eq(problem, 'IN needs at least one value')
  end)

  it('prefills the value prompt from the cell, wrapping a pattern in wildcards', function()
    local builder = require('dblens.ui.filterbuilder')
    local cell = { row = 1, column = 1, name = 'note', value = "o'brien" }
    local function prompts(op)
      local operator
      for _, entry in ipairs(filter.OPERATORS) do
        if entry.id == op then
          operator = entry
        end
      end
      return builder.prompts_for(cell, assert(operator, op))
    end

    eq(#prompts('IS NULL'), 0)
    local equals = prompts('=')
    eq(#equals, 1)
    eq(equals[1].default, "o'brien")
    eq(equals[1].label, 'note = ')

    local like = prompts('LIKE')
    eq(like[1].default, "%o'brien%")

    local between = prompts('BETWEEN')
    eq(#between, 2)
    eq(between[1].default, "o'brien")
    eq(between[2].default, '')

    -- A NULL cell has nothing to prefill, and no wildcards to wrap around it.
    local null_cell = { row = 1, column = 1, name = 'note', value = h.NULL }
    eq(
      builder.prompts_for(
        null_cell,
        { id = 'LIKE', label = 'LIKE', arity = 'one', wildcard = true }
      )[1].default,
      ''
    )
  end)
end)

describe('filter builder: combining with the filter already applied', function()
  it('ANDs both sides parenthesised, so an OR keeps its meaning', function()
    eq(
      filter.combine("a = '1' OR b = '2'", [["c" IS NULL]]),
      [[(a = '1' OR b = '2') AND ("c" IS NULL)]]
    )
  end)

  it('is just the new predicate when nothing is applied yet', function()
    eq(filter.combine(nil, [["c" IS NULL]]), [["c" IS NULL]])
    eq(filter.combine('  ', [["c" IS NULL]]), [["c" IS NULL]])
  end)

  it('stays one vetted statement after combining', function()
    local first = build('note', '=', { "x'; DROP TABLE victim; --" })
    local second = build('n', 'BETWEEN', { '1', '9' })
    local combined = filter.combine(first, second)
    eq(common.check_predicate(combined, DIALECT), nil, { fail_reason = combined })
    eq(#sqlmod.split(page_with(combined), DIALECT), 1, { fail_reason = combined })
  end)
end)

-- ---------------------------------------------------------------------------
-- what the grid actually sends

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

--- A UI open on a browsed table whose columns the catalog knows, with a fake client behind it.
local function open_on_table(session_mod, extra)
  local app = require('dblens.app')
  local options = scratch_options(extra)
  require('dblens.config').setup(options)
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.session = h.fake_session(session_mod, {}, options)
  state.session.catalog:set_part(RELATION, 'columns', {
    { name = 'id', type = 'integer', notnull = true, pk = 1 },
    { name = 'note', type = 'text', notnull = false, pk = 0 },
  })
  state.grid.source = { kind = 'relation', relation = RELATION, label = 'orders' }
  state.grid.result = { columns = { 'id', 'note' }, rows = { { '1', 'a' } }, malformed = 0 }
  return app, state
end

local function wire_page(stdin, total)
  local limit = tonumber(stdin:match('LIMIT (%d+)'))
  local offset = tonumber(stdin:match('OFFSET (%d+)'))
  assert(limit and offset, 'the page statement carried no LIMIT/OFFSET: ' .. stdin)
  local records = { h.record('id', 'note') }
  for id = offset + 1, math.min(offset + limit, total) do
    records[#records + 1] = h.record(tostring(id), 'note ' .. id)
  end
  return h.wire(records)
end

--- Drive `fn` with the page statements the grid asked the client for.
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

describe('app: applying a built filter', function()
  it('sends it server-side, composed with the sort and paged from the first page', function()
    with_pages(function(app, state, sent)
      app.sort_by('note')
      state.grid.paging.page = 3
      app.filter_with('note', 'LIKE', { '%a%' }, 'replace')
      eq(state.grid.paging.page, 1)
      local statement = last(sent)
      eq(statement:find([[WHERE "note" LIKE '%a%']], 1, true) ~= nil, true, {
        fail_reason = statement,
      })
      eq(statement:find('ORDER BY "note" ASC LIMIT 5 OFFSET 0', 1, true) ~= nil, true, {
        fail_reason = statement,
      })
      -- And paging from there keeps the WHERE.
      app.page(1)
      eq(last(sent):find([[WHERE "note" LIKE '%a%']], 1, true) ~= nil, true, {
        fail_reason = last(sent),
      })
      eq(last(sent):find('OFFSET 5', 1, true) ~= nil, true, { fail_reason = last(sent) })
    end, { page_size = 5 })
  end)

  it('ANDs onto the filter already applied, or replaces it', function()
    with_pages(function(app, state, sent)
      app.filter_with('note', '=', { 'a' }, 'replace')
      app.filter_with('id', '>', { '3' }, 'and')
      eq(state.grid.filter, [[("note" = 'a') AND ("id" > '3')]])
      eq(last(sent):find([[WHERE ("note" = 'a') AND ("id" > '3')]], 1, true) ~= nil, true, {
        fail_reason = last(sent),
      })
      app.filter_with('id', 'IS NULL', {}, 'replace')
      eq(state.grid.filter, '"id" IS NULL')
    end)
  end)

  it('refuses a value it cannot express, leaving the grid as it was', function()
    with_pages(function(app, state, sent)
      app.filter_with('note', '=', { 'a' }, 'replace')
      local before = #sent
      local said = {}
      local notify = vim.notify
      vim.notify = function(message)
        said[#said + 1] = message
      end
      app.filter_with('note', '=', { 'a\0b' }, 'replace')
      vim.notify = notify
      eq(#sent, before, { fail_reason = 'a refused filter still queried' })
      eq(state.grid.filter, [["note" = 'a']])
      eq(#said, 1)
      eq(said[1]:find('NUL', 1, true) ~= nil, true, { fail_reason = said[1] })
    end)
  end)

  it("needs a table: a query result is whatever the user's own statement returned", function()
    with_pages(function(app, state, sent)
      state.grid.source = { kind = 'query', label = 'query' }
      app.filter_with('note', '=', { 'a' }, 'replace')
      eq(#sent, 0)
      eq(state.grid.filter, nil)
    end)
  end)
end)

--- A LOCKED run must be PROVABLY one statement, and that proof is a byte scan that does not read
--- quoting — so a `;` in the value is refused while locked however correctly it is escaped. The
--- builder inherits that from filter-from-cell rather than having its own answer.
describe('app: a built filter carrying a `;` on a LOCKED connection', function()
  local function browsing(session_mod, spec)
    local options = scratch_options()
    local app = require('dblens.app')
    require('dblens.config').setup(options)
    app.open()
    local state = app.state()
    assert(state, 'app.open left no state')
    state.session = h.fake_session(session_mod, spec, options)
    state.grid.source = { kind = 'relation', relation = RELATION, label = 'orders' }
    state.grid.result = { columns = { 'note' }, rows = { { 'a;b' } }, malformed = 0 }
    return app, state
  end

  it('is refused, unsent, while LOCKED', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod, { read_only = true })
      app.filter_with('note', 'IN', { 'a;b', 'c' }, 'replace')
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
      app.filter_with('note', 'IN', { 'a;b', 'c' }, 'replace')
      eq(state.grid.filter, [["note" IN ('a;b', 'c')]])
      eq(calls[1].stdin:find([[WHERE "note" IN ('a;b', 'c')]], 1, true) ~= nil, true, {
        fail_reason = calls[1].stdin,
      })
      app.close()
    end)
  end)
end)

--- The whole interaction, with the two input surfaces scripted: pick an operator, answer the
--- prompts, choose how it combines. What this holds is the wiring — that the cell under the
--- cursor reaches `filter.build` and its output reaches the client.
describe('filter builder: the interaction end to end', function()
  --- Script the picker and `vim.ui.input`. `choices` are answered in order, one per picker; each
  --- `answers` entry is one prompt.
  local function scripted(choices, answers, fn)
    local picker = require('dblens.ui.picker')
    local real_select, real_input = picker.select, vim.ui.input
    local pick_at, answer_at = 0, 0
    picker.select = function(_, opts)
      pick_at = pick_at + 1
      local want = choices[pick_at]
      assert(want, ('picker %d was not scripted (title %s)'):format(pick_at, opts.title))
      for _, item in ipairs(opts.items) do
        local value = item.value
        if value == want or (type(value) == 'table' and value.id == want) then
          opts.on_choose(value)
          return
        end
      end
      error(('`%s` was not offered by the %s picker'):format(tostring(want), opts.title))
    end
    vim.ui.input = function(_, on_confirm)
      answer_at = answer_at + 1
      on_confirm(answers[answer_at])
    end
    local ok, err = pcall(fn)
    picker.select, vim.ui.input = real_select, real_input
    if not ok then
      error(err, 0)
    end
    return { picks = pick_at, answers = answer_at }
  end

  it('carries the cell value into the prompt and the predicate into the statement', function()
    with_pages(function(_, state, sent)
      local builder = require('dblens.ui.filterbuilder')
      local cell = { row = 1, column = 2, name = 'note', value = "o'brien" }
      -- The prompt arrives prefilled; the user accepts it unchanged.
      local defaults = {}
      local real_input = vim.ui.input
      vim.ui.input = function(opts, on_confirm)
        defaults[#defaults + 1] = opts.default
        on_confirm(opts.default)
      end
      local ok, err = pcall(function()
        local picker = require('dblens.ui.picker')
        local real_select = picker.select
        picker.select = function(_, opts)
          for _, item in ipairs(opts.items) do
            if item.value.id == 'LIKE' then
              opts.on_choose(item.value)
              return
            end
          end
          error('LIKE was not offered on a text column')
        end
        builder.open(state, cell)
        picker.select = real_select
      end)
      vim.ui.input = real_input
      assert(ok, tostring(err))
      eq(defaults, { "%o'brien%" })
      eq(state.grid.filter, [["note" LIKE '%o''brien%']])
      eq(last(sent):find([[WHERE "note" LIKE '%o''brien%']], 1, true) ~= nil, true, {
        fail_reason = last(sent),
      })
    end)
  end)

  it('asks how to combine only when a filter is already applied', function()
    with_pages(function(_, state)
      local builder = require('dblens.ui.filterbuilder')
      local cell = { row = 1, column = 1, name = 'id', value = '4' }

      local first = scripted({ '>' }, { '3' }, function()
        builder.open(state, cell)
      end)
      eq(first.picks, 1, { fail_reason = 'the combine question was asked with no filter applied' })
      eq(state.grid.filter, [["id" > '3']])

      local second = scripted({ 'BETWEEN', 'and' }, { '1', '9' }, function()
        builder.open(state, cell)
      end)
      eq(second.picks, 2)
      eq(second.answers, 2)
      eq(state.grid.filter, [[("id" > '3') AND ("id" BETWEEN '1' AND '9')]])

      scripted({ 'IN', 'replace' }, { '1, 2 ,3' }, function()
        builder.open(state, cell)
      end)
      eq(state.grid.filter, [["id" IN ('1', '2', '3')]])
    end)
  end)

  it('needs no value for IS NULL, and offers it first on a NULL cell', function()
    with_pages(function(_, state)
      local builder = require('dblens.ui.filterbuilder')
      local run = scripted({ 'IS NULL' }, {}, function()
        builder.open(state, { row = 1, column = 2, name = 'note', value = h.NULL })
      end)
      eq(run.answers, 0, { fail_reason = 'IS NULL asked for a value' })
      eq(state.grid.filter, '"note" IS NULL')
    end)
  end)

  it('abandons the filter when a prompt is cancelled', function()
    with_pages(function(_, state, sent)
      local builder = require('dblens.ui.filterbuilder')
      local before = #sent
      scripted({ '=' }, { nil }, function()
        builder.open(state, { row = 1, column = 2, name = 'note', value = 'a' })
      end)
      eq(state.grid.filter, nil)
      eq(#sent, before, { fail_reason = 'a cancelled filter still queried' })
    end)
  end)
end)

--- Live. Every predicate the builder generates is sent to a REAL server through the adapter's own
--- argv, against a table whose column is named `select` and whose values carry quotes, a `;` and
--- a `--`. What each filter matches is then the SERVER's answer, not this file's — and the table
--- a payload names is still there afterwards.
describe('live: a built filter is a read the server answers, on a hostile schema', function()
  local ROWS = {
    { id = '1', selected = "o'brien", note = 'alpha' },
    { id = '2', selected = [[x'; DROP TABLE victim; --]], note = 'beta' },
    { id = '3', selected = 'plain', note = 'gamma' },
  }
  local RELATION_LIVE = { name = 'orders', kind = 'table' }

  local function send(adapter, target, statement)
    local command = adapter.command(target.spec, target.secret, 'records', target.clients)
    return vim.system(command.argv, { env = command.env, stdin = statement }):wait(60000)
  end

  --- Seed the hostile schema, then ask the server what each generated filter matches.
  local function round_trip(adapter, target)
    local dialect = adapter.dialect
    local setup = {
      'DROP TABLE IF EXISTS orders;',
      'DROP TABLE IF EXISTS victim;',
      'CREATE TABLE victim(a int);',
      'CREATE TABLE orders(id int, "select" text, note text);',
    }
    for _, row in ipairs(ROWS) do
      setup[#setup + 1] = ('INSERT INTO orders VALUES (%s, %s, %s);'):format(
        row.id,
        sqlmod.quote_literal(row.selected, dialect),
        sqlmod.quote_literal(row.note, dialect)
      )
    end
    setup[#setup + 1] = "INSERT INTO orders VALUES (4, NULL, 'delta');"
    local created = send(adapter, target, table.concat(setup, '\n'))
    eq(created.code, 0, { fail_reason = tostring(created.stderr) })

    --- The ids the page statement built for this filter comes back with, sorted: nothing here
    --- asks for an order, so the plan's is not the assertion.
    local function ids(predicate)
      local statement =
        common.page(RELATION_LIVE, { limit = 50, offset = 0, where = predicate }, dialect)
      local answer = send(adapter, target, statement)
      eq(answer.code, 0, { fail_reason = statement .. ' -> ' .. tostring(answer.stderr) })
      local out = {}
      for _, row in ipairs(adapter.decode(answer.stdout, {}).rows) do
        out[#out + 1] = tostring(row[1])
      end
      table.sort(out)
      return out
    end
    local function ids_for(column, op, values)
      return ids(build(column, op, values, dialect))
    end

    -- The value that looks like a statement matches its own row and nothing else.
    eq(ids_for('select', '=', { ROWS[2].selected }), { '2' })
    eq(ids_for('select', '<>', { ROWS[2].selected }), { '1', '3' })
    eq(ids_for('select', 'LIKE', { "%o'brien%" }), { '1' })
    eq(ids_for('select', 'NOT LIKE', { '%plain%' }), { '1', '2' })
    eq(ids_for('select', 'IN', { ROWS[1].selected, 'plain' }), { '1', '3' })
    eq(ids_for('select', 'IS NULL', {}), { '4' })
    eq(ids_for('select', 'IS NOT NULL', {}), { '1', '2', '3' })
    eq(ids_for('note', 'BETWEEN', { 'alpha', 'beta' }), { '1', '2' })
    eq(ids_for('note', '>', { 'beta' }), { '3', '4' })
    if adapter.caps.ilike then
      eq(ids_for('select', 'ILIKE', { "%O'BRIEN%" }), { '1' })
    end
    -- Two predicates the builder composed, sent as one statement.
    eq(
      ids(
        filter.combine(
          build('select', 'IS NOT NULL', {}, dialect),
          build('note', 'LIKE', { 'b%' }, dialect)
        )
      ),
      { '2' }
    )

    -- Nothing the values named was executed: the table a payload would have dropped is still
    -- here, and every row is untouched.
    local survived = send(adapter, target, 'SELECT count(*) AS n FROM victim;')
    eq(survived.code, 0, { fail_reason = 'victim was dropped: ' .. tostring(survived.stderr) })
    local intact = send(adapter, target, 'SELECT count(*) AS n FROM orders;')
    eq(adapter.decode(intact.stdout, {}).rows[1][1], '4', { fail_reason = tostring(intact.stdout) })
  end

  it('sqlite', function()
    local live = h.live_file_client('sqlite')
    if not live then
      MiniTest.add_note('no sqlite3 client; the live filter-builder round trip did not run')
      return
    end
    round_trip(assert(require('dblens.adapters').get('sqlite')), {
      spec = { name = 'live', kind = 'sqlite', path = vim.fn.tempname() .. '.db' },
      clients = live.clients,
    })
  end)

  it('postgres', function()
    local target = h.live_target('postgres')
    if not target then
      MiniTest.add_note(
        'no postgres server (set DBLENS_TEST_POSTGRES_PORT); the live filter-builder round trip '
          .. 'did not run'
      )
      return
    end
    round_trip(assert(require('dblens.adapters').get('postgres')), target)
  end)
end)
