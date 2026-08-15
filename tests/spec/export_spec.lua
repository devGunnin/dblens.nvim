--- Export: the whole result, and never a short file that reads as a complete one.
---
--- The defect these cases exist for: `X` wrote `state.grid.result`, which for a browsed table is
--- ONE PAGE, and reported "exported 100 row(s)" — true, and therefore easy to miss — while the
--- README promised the whole result. A truncated query result went the same way, with
--- `state.grid.truncated` never consulted.
local h = require('helpers')

local export = require('dblens.export')
local sqlmod = require('dblens.sql')

local eq = h.eq

local DIALECT = sqlmod.dialects.sqlite
local RELATION = { name = 'orders', kind = 'table' }

local function scratch_dir()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return base
end

local function scratch_options(extra)
  local base = scratch_dir()
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
    discovery = { auto = false },
  }, extra or {})
end

local function read(path)
  local file = assert(io.open(path, 'r'), 'no file at ' .. path)
  local text = file:read('*a')
  file:close()
  return text
end

--- A source of `total` rows, answering each window the way a paged SELECT would.
local function paged_source(total, seen)
  return function(offset, limit, on_done)
    if seen then
      seen[#seen + 1] = { offset = offset, limit = limit }
    end
    local rows = {}
    for id = offset + 1, math.min(offset + limit, total) do
      rows[#rows + 1] = { tostring(id), 'name ' .. id }
    end
    on_done({ columns = { 'id', 'name' }, rows = rows, malformed = 0 }, nil)
  end
end

-- ---------------------------------------------------------------------------

describe('export: choosing a format', function()
  it('reads the format from the extension', function()
    eq(export.format_for('/tmp/a.csv'), 'csv')
    eq(export.format_for('/tmp/a.JSON'), 'json')
    eq(export.format_for('/tmp/a.sql'), 'sql')
  end)

  it('refuses an extension it does not know, instead of quietly writing CSV', function()
    local format, err = export.format_for('/tmp/rows.tsv')
    eq(format, nil)
    eq(err:find('.csv', 1, true) ~= nil, true, { fail_reason = err })
    eq(select(1, export.format_for('/tmp/rows')), nil)
  end)
end)

describe('export: the file is only replaced once the whole run succeeded', function()
  it('writes through a temp file and renames it into place', function()
    local dir = scratch_dir()
    local path = dir .. '/out.csv'
    export.stream({
      path = path,
      format = 'csv',
      max_rows = 100,
      batch = 2,
      fetch = paged_source(5),
    }, function(summary, err)
      eq(err, nil)
      eq(summary.rows, 5)
    end)
    eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n4,name 4\n5,name 5\n')
    eq(vim.fn.glob(dir .. '/*.tmp'), '', { fail_reason = 'a temp file was left behind' })
  end)

  it('leaves the previous file untouched when a fetch fails part-way', function()
    local dir = scratch_dir()
    local path = dir .. '/out.csv'
    local file = assert(io.open(path, 'w'))
    file:write('the file that was already there\n')
    file:close()

    local page = 0
    export.stream({
      path = path,
      format = 'csv',
      max_rows = 100,
      batch = 2,
      fetch = function(offset, limit, on_done)
        page = page + 1
        if page > 1 then
          on_done(nil, 'the client was cancelled')
          return
        end
        paged_source(50)(offset, limit, on_done)
      end,
    }, function(summary, err)
      eq(summary, nil)
      eq(err, 'the client was cancelled')
    end)

    eq(read(path), 'the file that was already there\n')
    eq(vim.fn.glob(dir .. '/*.tmp'), '', { fail_reason = 'an aborted export left its temp file' })
  end)
end)

describe('export: a cap stops the run and says so', function()
  it('reports the cap and records it in a format that can carry a comment', function()
    local dir = scratch_dir()
    local path = dir .. '/out.sql'
    local captured
    export.stream({
      path = path,
      format = 'sql',
      max_rows = 3,
      batch = 2,
      relation = RELATION,
      dialect = DIALECT,
      fetch = paged_source(100),
    }, function(summary)
      captured = summary
    end)

    eq(captured.rows, 3)
    eq(captured.capped, true, { fail_reason = 'a capped export reported itself as complete' })
    local text = read(path)
    eq(select(2, text:gsub('INSERT INTO', '')), 3, { fail_reason = text })
    eq(text:find('NOT the whole result', 1, true) ~= nil, true, { fail_reason = text })
  end)

  it('does not claim a cap when the source simply ran out on the boundary', function()
    local captured
    export.stream({
      path = scratch_dir() .. '/out.csv',
      format = 'csv',
      max_rows = 10,
      batch = 4,
      fetch = paged_source(10),
    }, function(summary)
      captured = summary
    end)
    eq(captured.rows, 10)
    eq(captured.capped, false)
  end)

  it('asks for no more rows than the cap leaves, then one to settle whether any are', function()
    local seen = {}
    export.stream({
      path = scratch_dir() .. '/out.csv',
      format = 'csv',
      max_rows = 5,
      batch = 4,
      fetch = paged_source(100, seen),
    }, function(summary)
      eq(summary.rows, 5)
      eq(summary.capped, true)
    end)
    eq(seen, {
      { offset = 0, limit = 4 },
      { offset = 4, limit = 1 },
      -- The probe: it decides the report, and its row is never written.
      { offset = 5, limit = 1 },
    })
  end)
end)

describe('export: the formats', function()
  local function write_all(format, opts)
    local path = scratch_dir() .. '/out.' .. format
    export.stream(
      vim.tbl_extend('force', {
        path = path,
        format = format,
        max_rows = 100,
        batch = 2,
        fetch = paged_source(3),
      }, opts or {}),
      function(_, err)
        eq(err, nil)
      end
    )
    return read(path)
  end

  it('writes CSV with a single header, across chunk boundaries', function()
    eq(write_all('csv'), 'id,name\n1,name 1\n2,name 2\n3,name 3\n')
  end)

  it('writes JSON that parses back to the rows', function()
    eq(vim.json.decode(write_all('json')), {
      { id = '1', name = 'name 1' },
      { id = '2', name = 'name 2' },
      { id = '3', name = 'name 3' },
    })
  end)

  it('writes INSERT statements, quoted for the dialect', function()
    local text = write_all('sql', { relation = RELATION, dialect = DIALECT })
    eq(
      text,
      [[INSERT INTO "orders" ("id", "name") VALUES ('1', 'name 1');]]
        .. '\n'
        .. [[INSERT INTO "orders" ("id", "name") VALUES ('2', 'name 2');]]
        .. '\n'
        .. [[INSERT INTO "orders" ("id", "name") VALUES ('3', 'name 3');]]
        .. '\n'
    )
  end)

  it('needs a table for INSERTs rather than inventing one for a query result', function()
    local writer, err = export.open(scratch_dir() .. '/out.sql', 'sql')
    eq(writer, nil)
    eq(err:find('needs a table', 1, true) ~= nil, true, { fail_reason = err })
  end)

  it('escapes a value that would otherwise end the statement it is written into', function()
    local path = scratch_dir() .. '/out.sql'
    export.write(
      { columns = { 'c' }, rows = { { "x'); DROP TABLE t; --" } }, malformed = 0 },
      path,
      'sql',
      { relation = RELATION, dialect = DIALECT }
    )
    local text = vim.trim(read(path))
    eq(#sqlmod.split(text, DIALECT), 1, { fail_reason = text })
    eq(sqlmod.classify(text, DIALECT).verb, 'INSERT')
  end)
end)

describe('export: the path is expanded without a shell', function()
  it('refuses a path a shell expander would evaluate', function()
    local writer, err = export.open('/tmp/`id`.csv', 'csv')
    eq(writer, nil)
    eq(err:find('backtick', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('substitutes $VAR textually and writes where it points', function()
    local dir = scratch_dir()
    vim.env.DBLENS_TEST_EXPORT_DIR = dir
    local ok, err = export.write(
      { columns = { 'c' }, rows = { { '1' } }, malformed = 0 },
      '$DBLENS_TEST_EXPORT_DIR/out.csv',
      'csv'
    )
    vim.env.DBLENS_TEST_EXPORT_DIR = nil
    eq(ok, true, { fail_reason = tostring(err) })
    eq(read(dir .. '/out.csv'), 'c\n1\n')
  end)

  it('names a directory that is not there instead of failing obscurely', function()
    local ok, err =
      export.write({ columns = { 'c' }, rows = {}, malformed = 0 }, '/no/such/place/out.csv', 'csv')
    eq(ok, false)
    eq(err:find('directory does not exist', 1, true) ~= nil, true, { fail_reason = err })
  end)
end)

-- ---------------------------------------------------------------------------

local function open_with_session(session_mod, extra)
  local app = require('dblens.app')
  local options = scratch_options(extra)
  require('dblens.config').setup(options)
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.session = h.fake_session(session_mod, {}, options)
  return app, state
end

--- Client stdout for `SELECT * FROM ... LIMIT n OFFSET k` against a table of `total` rows.
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

describe('export: the grid writes the whole table, not the page on screen', function()
  local exporter = require('dblens.ui.exporter')

  it('re-reads every page, so the file is the result and not the window into it', function()
    h.with_fake_exec(function(call)
      if call.stdin:find('SELECT * FROM', 1, true) then
        return { stdout = wire_page(call.stdin, 5) }
      end
      return {}
    end, function(session_mod)
      -- page_size 2 is what the old code exported: one page of a five-row table.
      local app, state = open_with_session(session_mod, {
        page_size = 2,
        export = { batch_size = 2, max_rows = 1000 },
      })
      state.grid.source = { kind = 'relation', relation = RELATION, label = 'orders' }
      state.grid.result = {
        columns = { 'id', 'name' },
        rows = { { '1', 'name 1' }, { '2', 'name 2' } },
        malformed = 0,
      }

      local path = scratch_dir() .. '/out.csv'
      exporter.current(state, { path = path, format = 'csv' })

      eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n4,name 4\n5,name 5\n')
      app.close()
    end)
  end)

  it('carries the grid filter and sort into the export, so the file matches the view', function()
    local sent = {}
    h.with_fake_exec(function(call)
      if call.stdin:find('SELECT * FROM', 1, true) then
        sent[#sent + 1] = call.stdin
        return { stdout = wire_page(call.stdin, 1) }
      end
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod, { export = { batch_size = 50 } })
      state.grid.source = { kind = 'relation', relation = RELATION, label = 'orders' }
      state.grid.result = { columns = { 'id', 'name' }, rows = {}, malformed = 0 }
      state.grid.filter = "id > '3'"
      state.grid.sort = { column = 'id', desc = true }

      exporter.current(state, { path = scratch_dir() .. '/out.csv', format = 'csv' })

      eq(#sent, 1)
      eq(sent[1]:find("WHERE id > '3'", 1, true) ~= nil, true, { fail_reason = sent[1] })
      eq(sent[1]:find('ORDER BY "id" DESC', 1, true) ~= nil, true, { fail_reason = sent[1] })
      app.close()
    end)
  end)

  it('exports a whole table straight from the tree', function()
    h.with_fake_exec(function(call)
      if call.stdin:find('SELECT * FROM', 1, true) then
        return { stdout = wire_page(call.stdin, 3) }
      end
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod, { export = { batch_size = 2 } })
      local path = scratch_dir() .. '/table.csv'
      exporter.relation(state, RELATION, { path = path, format = 'csv' })
      eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n')
      app.close()
    end)
  end)

  it('reads the export through the gate, so a LOCKED connection stays locked', function()
    h.with_fake_exec(function(call)
      if call.stdin:find('SELECT * FROM', 1, true) then
        return { stdout = wire_page(call.stdin, 1) }
      end
      return {}
    end, function(session_mod, calls)
      local options = scratch_options({ export = { batch_size = 50 } })
      local app, state = open_with_session(session_mod, { export = { batch_size = 50 } })
      state.session = h.fake_session(session_mod, { read_only = true }, options)

      exporter.relation(state, RELATION, { path = scratch_dir() .. '/out.csv', format = 'csv' })

      eq(#calls, 1)
      -- The export goes through `session:run` like every other read, so the client it spawns is
      -- the LOCKED one: on sqlite `-readonly` is the file open mode, and that IS the guarantee.
      eq(h.has(calls[1].argv, '-readonly'), true, {
        fail_reason = 'the export spawned a writable client: ' .. table.concat(calls[1].argv, ' '),
      })
      app.close()
    end)
  end)
end)

describe('export: the prompt guards the file it is about to replace', function()
  local exporter = require('dblens.ui.exporter')
  local confirm = require('dblens.ui.confirm')

  --- Drive the prompt with a scripted path, and record whether it asked before overwriting.
  ---@return table? asked  -- the confirmation it raised, or nil when it went straight through
  local function prompt_with(state, path, answer)
    local real_input, real_ask = vim.ui.input, confirm.ask
    local asked = nil
    vim.ui.input = function(_, on_input)
      on_input(path)
    end
    confirm.ask = function(_, opts, on_confirm)
      asked = opts
      if answer == 'yes' then
        on_confirm()
      end
    end
    local ok, err = pcall(exporter.prompt_relation, state, RELATION)
    vim.ui.input, confirm.ask = real_input, real_ask
    assert(ok, tostring(err))
    return asked
  end

  local function browsing(session_mod)
    local app = require('dblens.app')
    local options = scratch_options({ export = { batch_size = 50 } })
    require('dblens.config').setup(options)
    app.open()
    local state = app.state()
    assert(state, 'app.open left no state')
    state.session = h.fake_session(session_mod, {}, options)
    return app, state
  end

  it('writes a new file without asking', function()
    h.with_fake_exec(function(call)
      return { stdout = wire_page(call.stdin, 2) }
    end, function(session_mod)
      local app, state = browsing(session_mod)
      local path = scratch_dir() .. '/new.csv'
      eq(
        prompt_with(state, path, 'yes'),
        nil,
        { fail_reason = 'asked about a file that is not there' }
      )
      eq(read(path), 'id,name\n1,name 1\n2,name 2\n')
      app.close()
    end)
  end)

  it('asks before replacing one, and replaces it only on yes', function()
    h.with_fake_exec(function(call)
      return { stdout = wire_page(call.stdin, 2) }
    end, function(session_mod)
      local app, state = browsing(session_mod)
      local path = scratch_dir() .. '/existing.csv'
      local file = assert(io.open(path, 'w'))
      file:write('do not lose me\n')
      file:close()

      local asked = prompt_with(state, path, 'no')
      eq(asked ~= nil, true, { fail_reason = 'an existing file was replaced with no confirmation' })
      eq(asked.title:find('Overwrite', 1, true) ~= nil, true, { fail_reason = asked.title })
      eq(read(path), 'do not lose me\n', { fail_reason = 'a declined overwrite still wrote' })

      prompt_with(state, path, 'yes')
      eq(read(path), 'id,name\n1,name 1\n2,name 2\n')
      app.close()
    end)
  end)

  it('refuses a path a shell expander would evaluate, before opening anything', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod)
      eq(prompt_with(state, '/tmp/`id`.csv', 'yes'), nil)
      eq(#calls, 0, { fail_reason = 'a rejected path still started an export' })
      app.close()
    end)
  end)

  it('refuses an extension naming no format, rather than writing CSV under it', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = browsing(session_mod)
      local path = scratch_dir() .. '/rows.tsv'
      prompt_with(state, path, 'yes')
      eq(#calls, 0)
      eq(vim.fn.filereadable(path), 0)
      app.close()
    end)
  end)
end)

describe('export: a query result that cannot be re-read says what is missing', function()
  local exporter = require('dblens.ui.exporter')

  it('re-runs a single read to get past the render cap', function()
    local sent = {}
    h.with_fake_exec(function(call)
      sent[#sent + 1] = call.stdin
      return { stdout = h.wire({ h.record('id'), h.record('1'), h.record('2') }) }
    end, function(session_mod)
      local app, state = open_with_session(session_mod, { max_rows = 1 })
      state.grid.source = { kind = 'query', sql = 'SELECT id FROM orders', label = 'query' }
      -- What the grid holds after `present` cut it to `max_rows`.
      state.grid.result = { columns = { 'id' }, rows = { { '1' } }, malformed = 0 }
      state.grid.truncated = true

      local path = scratch_dir() .. '/out.csv'
      exporter.current(state, { path = path, format = 'csv' })

      eq(sent, { 'SELECT id FROM orders' })
      eq(read(path), 'id\n1\n2\n', { fail_reason = 'the export wrote the truncated rows' })
      app.close()
    end)
  end)

  it('will not re-run a script that writes, and states the shortfall instead', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod, { max_rows = 1 })
      state.grid.source =
        { kind = 'query', sql = 'INSERT INTO t VALUES (1); SELECT * FROM t', label = 'query' }
      state.grid.result = { columns = { 'id' }, rows = { { '1' } }, malformed = 0 }
      state.grid.truncated = true

      local path = scratch_dir() .. '/out.sql'
      exporter.current(state, { path = path, format = 'sql' })

      eq(#calls, 0, { fail_reason = 'the export re-ran a script that writes' })
      -- A query result has no table, so the sql format is refused and nothing is written at all.
      eq(vim.fn.filereadable(path), 0)

      local csv = scratch_dir() .. '/out.csv'
      exporter.current(state, { path = csv, format = 'csv' })
      eq(read(csv), 'id\n1\n')
      app.close()
    end)
  end)
end)
