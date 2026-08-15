--- Export: the whole result, and never a short file that reads as a complete one.
---
--- The defect these cases exist for: `X` wrote `state.grid.result`, which for a browsed table is
--- ONE PAGE, and reported "exported 100 row(s)" — true, and therefore easy to miss — while the
--- README promised the whole result. A truncated query result went the same way, with
--- `state.grid.truncated` never consulted.
---
--- The second defect, which the first fix introduced: reading the table back page by page, each
--- page its own client process, is not a consistent read. A row deleted between two pages shifted
--- every later row up, so the file quietly lost one it never read and kept one that no longer
--- existed — and still reported success. The export is now ONE statement in ONE invocation, which
--- is what `only one client invocation` below is really asserting.
local MiniTest = require('mini.test')
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

--- One query's rows, arriving in batches the way a streamed client's output does.
---
--- `available` is what the table holds and `limit` is the statement's own LIMIT, so a run that
--- yields `limit` rows is exactly the case where the cap, and not the table, decided where the
--- file ended.
local function query_source(available, limit, batch)
  local supply = math.min(available, limit)
  return function(sink, on_done)
    local sent = 0
    while sent < supply do
      local rows = {}
      for id = sent + 1, math.min(sent + batch, supply) do
        rows[#rows + 1] = { tostring(id), 'name ' .. id }
      end
      sent = sent + #rows
      local problem = sink({ 'id', 'name' }, rows)
      if problem then
        on_done(problem)
        return
      end
    end
    -- A result with no rows still carries its columns, so the header is written either way.
    if sent == 0 then
      sink({ 'id', 'name' }, {})
    end
    on_done(nil)
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
      run = query_source(5, 101, 2),
    }, function(summary, err)
      eq(err, nil)
      eq(summary.rows, 5)
    end)
    eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n4,name 4\n5,name 5\n')
    eq(vim.fn.glob(dir .. '/*.tmp'), '', { fail_reason = 'a temp file was left behind' })
  end)

  it('leaves the previous file untouched when the read fails part-way', function()
    local dir = scratch_dir()
    local path = dir .. '/out.csv'
    local file = assert(io.open(path, 'w'))
    file:write('the file that was already there\n')
    file:close()

    export.stream({
      path = path,
      format = 'csv',
      max_rows = 100,
      run = function(sink, on_done)
        sink({ 'id', 'name' }, { { '1', 'name 1' }, { '2', 'name 2' } })
        on_done('the client was cancelled')
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
      relation = RELATION,
      dialect = DIALECT,
      run = query_source(100, 4, 2),
    }, function(summary)
      captured = summary
    end)

    eq(captured.rows, 3)
    eq(captured.capped, true, { fail_reason = 'a capped export reported itself as complete' })
    local text = read(path)
    eq(select(2, text:gsub('INSERT INTO', '')), 3, { fail_reason = text })
    eq(text:find('NOT the whole result', 1, true) ~= nil, true, { fail_reason = text })
  end)

  it('does not claim a cap when the table simply ran out on the boundary', function()
    local captured
    export.stream({
      path = scratch_dir() .. '/out.csv',
      format = 'csv',
      max_rows = 10,
      run = query_source(10, 11, 4),
    }, function(summary)
      captured = summary
    end)
    eq(captured.rows, 10)
    eq(captured.capped, false)
  end)

  it('never writes the row past the cap, which is only there to prove the cap was hit', function()
    local path = scratch_dir() .. '/out.csv'
    export.stream({
      path = path,
      format = 'csv',
      max_rows = 3,
      run = query_source(100, 4, 4),
    }, function(summary)
      eq(summary.rows, 3)
      eq(summary.capped, true)
    end)
    eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n')
  end)

  it('marks a capped csv beside itself, since csv has nowhere to say it', function()
    local path = scratch_dir() .. '/out.csv'
    export.stream({
      path = path,
      format = 'csv',
      max_rows = 2,
      run = query_source(100, 3, 3),
    }, function(summary, err)
      eq(err, nil)
      eq(summary.capped, true)
    end)
    local marker = read(export.marker_for(path))
    eq(marker:find('NOT the whole result', 1, true) ~= nil, true, { fail_reason = marker })
  end)

  it('clears a stale marker when a later complete export replaces the file', function()
    local path = scratch_dir() .. '/out.csv'
    local stale = assert(io.open(export.marker_for(path), 'w'))
    stale:write('left by an earlier capped run\n')
    stale:close()

    export.stream({
      path = path,
      format = 'csv',
      max_rows = 100,
      run = query_source(2, 101, 2),
    }, function(summary, err)
      eq(err, nil)
      eq(summary.capped, false)
    end)
    eq(vim.fn.filereadable(export.marker_for(path)), 0, {
      fail_reason = 'a complete file kept a marker calling it incomplete',
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
        run = query_source(3, 101, 2),
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
---@param names string[]?  -- row values, defaulting to `name <id>`
local function wire_page(stdin, total, names)
  local limit = tonumber(stdin:match('LIMIT (%d+)'))
  local offset = tonumber(stdin:match('OFFSET (%d+)'))
  assert(limit and offset, 'the page statement carried no LIMIT/OFFSET: ' .. stdin)
  local records = { h.record('id', 'name') }
  for id = offset + 1, math.min(offset + limit, total) do
    records[#records + 1] = h.record(tostring(id), names and names[id] or ('name ' .. id))
  end
  return h.wire(records)
end

describe('export: the grid writes the whole table, not the page on screen', function()
  local exporter = require('dblens.ui.exporter')

  it('reads the whole table, not the window the grid holds', function()
    h.with_fake_exec(function(call)
      if call.stdin:find('SELECT * FROM', 1, true) then
        return { stdout = wire_page(call.stdin, 5) }
      end
      return {}
    end, function(session_mod)
      -- page_size 2 is what the old code exported: one page of a five-row table.
      local app, state = open_with_session(session_mod, {
        page_size = 2,
        export = { max_rows = 1000 },
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

  --- The consistency defect, driven deterministically: the table CHANGES the moment a second read
  --- would happen. A paged export took the file from both versions and reported it complete; one
  --- statement can only ever see one of them, so there is nothing to stitch and nothing to lose.
  it('reads it in ONE statement, so a write between reads cannot skew the file', function()
    local before = { 'a', 'b', 'c', 'd' }
    local reads = 0
    h.with_fake_exec(function(call)
      if not call.stdin:find('SELECT * FROM', 1, true) then
        return {}
      end
      reads = reads + 1
      -- Every read after the first sees a table one row shorter, with the rest shifted up.
      if reads == 1 then
        return { stdout = wire_page(call.stdin, 4, before) }
      end
      return { stdout = wire_page(call.stdin, 3, { 'a', 'c', 'd' }) }
    end, function(session_mod)
      local app, state = open_with_session(session_mod, { export = { max_rows = 1000 } })
      local path = scratch_dir() .. '/table.csv'
      exporter.relation(state, RELATION, { path = path, format = 'csv' })

      eq(reads, 1, { fail_reason = ('the export read the table %d times'):format(reads) })
      eq(read(path), 'id,name\n1,a\n2,b\n3,c\n4,d\n')
      app.close()
    end)
  end)

  it('asks for one row past the cap, so a capped run is told from an exhausted one', function()
    local sent = {}
    h.with_fake_exec(function(call)
      if call.stdin:find('SELECT * FROM', 1, true) then
        sent[#sent + 1] = call.stdin
        return { stdout = wire_page(call.stdin, 100) }
      end
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod, { export = { max_rows = 3 } })
      local path = scratch_dir() .. '/table.csv'
      exporter.relation(state, RELATION, { path = path, format = 'csv' })

      eq(#sent, 1)
      eq(sent[1]:find('LIMIT 4 OFFSET 0', 1, true) ~= nil, true, { fail_reason = sent[1] })
      eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n')
      local marker = read(export.marker_for(path))
      eq(marker:find('NOT the whole result', 1, true) ~= nil, true, { fail_reason = marker })
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
      local app, state = open_with_session(session_mod)
      state.grid.source = { kind = 'relation', relation = RELATION, label = 'orders' }
      state.grid.result = { columns = { 'id', 'name' }, rows = {}, malformed = 0 }
      state.grid.filter = "id > '3'"
      state.grid.sort = { column = 'name', desc = true }
      -- A loaded catalog, so the primary key is there to break ties with.
      state.session.catalog:set_part(RELATION, 'columns', {
        { name = 'id', type = 'int', notnull = true, pk = 1 },
        { name = 'name', type = 'text', notnull = false, pk = 0 },
      })

      exporter.current(state, { path = scratch_dir() .. '/out.csv', format = 'csv' })

      eq(#sent, 1)
      eq(sent[1]:find("WHERE id > '3'", 1, true) ~= nil, true, { fail_reason = sent[1] })
      -- The primary key is appended so two rows with the same name have ONE order, rather than
      -- whichever the plan happened to produce this time.
      eq(sent[1]:find('ORDER BY "name" DESC, "id" ASC', 1, true) ~= nil, true, {
        fail_reason = sent[1],
      })
      app.close()
    end)
  end)

  it('leaves an unsorted export unsorted rather than sorting a whole table for looks', function()
    local sent = {}
    h.with_fake_exec(function(call)
      if call.stdin:find('SELECT * FROM', 1, true) then
        sent[#sent + 1] = call.stdin
        return { stdout = wire_page(call.stdin, 1) }
      end
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      state.session.catalog:set_part(RELATION, 'columns', {
        { name = 'id', type = 'int', notnull = true, pk = 1 },
      })
      exporter.relation(state, RELATION, { path = scratch_dir() .. '/out.csv', format = 'csv' })
      eq(#sent, 1)
      eq(sent[1]:find('ORDER BY', 1, true), nil, { fail_reason = sent[1] })
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
      local app, state = open_with_session(session_mod)
      local path = scratch_dir() .. '/table.csv'
      exporter.relation(state, RELATION, { path = path, format = 'csv' })
      eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n')
      app.close()
    end)
  end)

  it('writes the header of a table with no rows at all', function()
    h.with_fake_exec(function()
      return { stdout = '' }
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      state.session.catalog:set_part(RELATION, 'columns', {
        { name = 'id', type = 'int', notnull = true, pk = 1 },
        { name = 'name', type = 'text', notnull = false, pk = 0 },
      })
      local path = scratch_dir() .. '/empty.csv'
      exporter.relation(state, RELATION, { path = path, format = 'csv' })
      eq(read(path), 'id,name\n')
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
      local options = scratch_options()
      local app, state = open_with_session(session_mod)
      state.session = h.fake_session(session_mod, { read_only = true }, options)

      exporter.relation(state, RELATION, { path = scratch_dir() .. '/out.csv', format = 'csv' })

      eq(#calls, 1)
      -- The export goes through the same gate as every other read, so the client it spawns is the
      -- LOCKED one: on sqlite `-readonly` is the file open mode, and that IS the guarantee.
      eq(h.has(calls[1].argv, '-readonly'), true, {
        fail_reason = 'the export spawned a writable client: ' .. table.concat(calls[1].argv, ' '),
      })
      app.close()
    end)
  end)

  it('takes the rows a chunk at a time, however the client cuts its output', function()
    local wire = wire_page('LIMIT 1001 OFFSET 0', 4)
    h.with_fake_exec(function(call)
      if not call.stdin:find('SELECT * FROM', 1, true) then
        return {}
      end
      -- Cut mid-record, so a reader that decoded each chunk on its own would lose or split a row.
      return { chunks = { wire:sub(1, 9), wire:sub(10, 21), wire:sub(22) } }
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      local path = scratch_dir() .. '/chunked.csv'
      exporter.relation(state, RELATION, { path = path, format = 'csv' })
      eq(read(path), 'id,name\n1,name 1\n2,name 2\n3,name 3\n4,name 4\n')
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
    local options = scratch_options()
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

-- ---------------------------------------------------------------------------
-- live: the file IS the database

local protocol = require('dblens.protocol')

--- Drive an export the way `ui.exporter` does — ONE statement, streamed to the file — against a
--- real client. Synchronous, so the assertions can go and read the database afterwards.
---
---@param opts { max_rows: integer?, columns: string[]?, during: fun()? }
---@return table? summary, string? err
local function live_export(session, relation, path, format, opts)
  opts = opts or {}
  local cap = opts.max_rows or 100000
  local statement = session.adapter.sql.page(relation, { limit = cap + 1, offset = 0 })
  local finished, summary, failure = false, nil, nil
  local during, armed = opts.during, false
  export.stream({
    path = path,
    format = format,
    max_rows = cap,
    relation = relation,
    dialect = session.adapter.dialect,
    run = function(sink, on_done)
      session:stream(statement, {
        columns = opts.columns,
        on_rows = function(columns, rows)
          -- Only ARMS the write: `on_rows` is the client's own output callback, so a fast event
          -- context, and driving another client from in there is exactly what is barred.
          armed = true
          return sink(columns, rows)
        end,
      }, function(_, err)
        on_done(err)
      end)
    end,
  }, function(result, err)
    summary, failure, finished = result, err, true
  end)
  assert(
    vim.wait(60000, function()
      -- The concurrent write, on the main loop, while the export is still in flight.
      if armed and during then
        during()
        during = nil
      end
      return finished
    end),
    'live export: the run never finished'
  )
  return summary, failure
end

--- A session over a real client, locked, exactly as an export runs.
local function live_session(spec, clients, secret)
  local options = require('dblens.config').setup({ clients = clients })
  local session, err = require('dblens.session').new(spec, options)
  assert(session, tostring(err))
  session.secret = secret
  session.connected = true
  return session
end

--- The file-backed engines, live. The single most valuable claim of this release — the file is
--- the database — with a real client, real values that break naive quoting, and a `.sql` file
--- replayed back. Both drive the record protocol, so both exercise the framing a streamed read
--- cuts its chunks on; they differ only in the flags their shell spells CSV with.
--- `csv` is how each shell is asked for plain CSV with an empty NULL, which is what dblens writes
--- — duckdb prints the text `NULL` for it otherwise, and the comparison would be against the
--- reference tool's spelling rather than against the data.
local FILE_ENGINES = {
  sqlite = { extension = 'db', csv = { '-csv', '-header' } },
  duckdb = { extension = 'duckdb', csv = { '-csv', '-nullvalue', '' } },
}

local function describe_live_file(kind)
  describe(('%s, live: an exported file is the database'):format(kind), function()
    local target, scratch = nil, nil
    local TABLE = { name = 't', kind = 'table' }
    local flags = FILE_ENGINES[kind]

    local ROWS = {
      "O'Brien",
      'a,b "quoted"',
      'line1\nline2',
      'héllo 世界',
      'back\\slash',
      'NULL',
      ';DROP TABLE t;--',
      '',
    }

    local function client(db, sql, extra)
      local argv = { target.client, '-batch', '-bail' }
      vim.list_extend(argv, extra or {})
      argv[#argv + 1] = db
      return vim.system(argv, { stdin = sql }):wait(60000)
    end

    local function seed()
      local db = ('%s/live-%d.%s'):format(scratch, math.random(1, 2 ^ 30), flags.extension)
      local statements = { 'CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);' }
      for index, value in ipairs(ROWS) do
        statements[#statements + 1] = ("INSERT INTO t VALUES (%d, '%s');"):format(
          index,
          value:gsub("'", "''")
        )
      end
      statements[#statements + 1] = ('INSERT INTO t VALUES (%d, NULL);'):format(#ROWS + 1)
      local made = client(db, table.concat(statements, '\n'))
      assert(
        made.code == 0,
        'export_spec: could not seed ' .. kind .. ': ' .. tostring(made.stderr)
      )
      return db
    end

    local function skip()
      if target then
        return false
      end
      MiniTest.add_note(('%s is not installed; the live export proof did not run'):format(kind))
      return true
    end

    before_each(function()
      target = h.live_file_client(kind)
      scratch = vim.fn.tempname()
      vim.fn.mkdir(scratch, 'p')
    end)

    after_each(function()
      if scratch then
        vim.fn.delete(scratch, 'rf')
      end
    end)

    it('writes a CSV that parses row for row identical to what the client prints', function()
      if skip() then
        return
      end
      local db = seed()
      local session = live_session({ name = 'live', kind = kind, path = db }, target.clients)
      local path = scratch .. '/out.csv'
      local summary, err = live_export(session, TABLE, path, 'csv')
      eq(err, nil)
      eq(summary.capped, false)
      eq(summary.rows, #ROWS + 1)

      local reference = client(db, 'SELECT * FROM t ORDER BY id;', flags.csv)
      eq(reference.code, 0, { fail_reason = tostring(reference.stderr) })
      eq(protocol.decode_csv(read(path)), protocol.decode_csv(reference.stdout))
    end)

    it('writes a .sql file that replays into an identical table', function()
      if skip() then
        return
      end
      local db = seed()
      local session = live_session({ name = 'live', kind = kind, path = db }, target.clients)
      local path = scratch .. '/out.sql'
      local _, err = live_export(session, TABLE, path, 'sql')
      eq(err, nil)

      local fresh = ('%s/replayed.%s'):format(scratch, flags.extension)
      assert(client(fresh, 'CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);').code == 0)
      local replay = client(fresh, read(path))
      eq(replay.code, 0, { fail_reason = 'the .sql did not replay: ' .. tostring(replay.stderr) })

      -- `typeof` is in the projection so NULL and the empty string cannot both read as empty.
      local query = 'SELECT id, typeof(v), v FROM t ORDER BY id;'
      local before = client(db, query, flags.csv)
      local after = client(fresh, query, flags.csv)
      eq(
        after.stdout,
        before.stdout,
        { fail_reason = 'the replayed table differs from the source' }
      )
      -- The payload row replayed as DATA: the table is still there afterwards.
      local counted = client(fresh, 'SELECT count(*) AS n FROM t;', flags.csv)
      eq(protocol.decode_csv(counted.stdout).rows[1][1], tostring(#ROWS + 1))
    end)
  end)
end

describe_live_file('sqlite')
describe_live_file('duckdb')

--- postgres, live. THE consistency case: postgres lets a writer commit while a reader is
--- streaming, so this is the engine where the paged export really did produce a skewed file and
--- call it complete. One statement is one snapshot; a write that lands during the run belongs to
--- the next one.
describe('postgres, live: an export is one snapshot, whatever lands during it', function()
  local target = nil
  local TABLE = { schema = 'public', name = 'export_race', kind = 'table' }
  local TOTAL = 5000

  local function psql(statement)
    local adapter = require('dblens.adapters').get('postgres')
    local spec = vim.tbl_extend('force', target.spec, { read_only = false })
    local command = adapter.command(spec, target.secret, 'records', target.clients)
    return vim.system(command.argv, { env = command.env, stdin = statement }):wait(60000)
  end

  local function seed()
    local out = psql(([[
DROP TABLE IF EXISTS export_race;
CREATE TABLE export_race(id int PRIMARY KEY, v text);
INSERT INTO export_race SELECT g, 'row ' || g FROM generate_series(1, %d) g;
]]):format(TOTAL))
    assert(out.code == 0, 'export_spec: could not seed postgres: ' .. tostring(out.stderr))
  end

  local function skip()
    if target then
      return false
    end
    MiniTest.add_note(
      'no postgres server (set DBLENS_TEST_POSTGRES_PORT); the live snapshot proof did not run'
    )
    return true
  end

  before_each(function()
    target = h.live_target('postgres')
  end)

  it('exports every row of the snapshot it started from, and no row twice', function()
    if skip() then
      return
    end
    seed()
    local session = live_session(vim.deepcopy(target.spec), target.clients, target.secret)
    local dir = scratch_dir()
    local path = dir .. '/race.csv'

    local deleted = nil
    local summary, err = live_export(session, TABLE, path, 'csv', {
      during = function()
        deleted = psql('DELETE FROM export_race WHERE id = 2;')
      end,
    })
    eq(err, nil)
    eq(summary.capped, false)
    assert(deleted, 'the concurrent write never ran, so this proves nothing')
    eq(
      deleted.code,
      0,
      { fail_reason = 'the concurrent DELETE failed: ' .. tostring(deleted.stderr) }
    )

    -- The table lost a row while the export was running.
    local remaining = psql('SELECT count(*) FROM export_race;')
    eq(vim.trim(remaining.stdout):match('%d+'), tostring(TOTAL - 1))

    -- The FILE is the snapshot the statement started from: every id once, none missing, none
    -- extra. The paged export skipped a row it never read and kept one that no longer existed.
    local exported = protocol.decode_csv(read(path))
    eq(#exported.rows, TOTAL, { fail_reason = ('the file holds %d rows'):format(#exported.rows) })
    local seen = {}
    for _, row in ipairs(exported.rows) do
      local id = tonumber(row[1])
      assert(id and not seen[id], ('id %s appears twice in the file'):format(tostring(row[1])))
      seen[id] = true
    end
    for id = 1, TOTAL do
      assert(seen[id], ('the file is missing id %d, which existed for the whole run'):format(id))
    end
  end)
end)
