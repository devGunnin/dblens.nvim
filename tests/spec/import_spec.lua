--- Importing a CSV into a table.
---
--- The most security-sensitive path in dblens: the DATA comes from outside the database. Four
--- claims are proved here, and each has a case that fails loudly if it stops being true.
---  * a hostile cell is DATA - the generated INSERT is one statement that stores the payload;
---  * a LOCKED connection imports nothing, and never gets as far as asking for a file;
---  * a row that fails takes the whole import with it, and the user is told which row;
---  * a table exported to CSV and imported back is the same table.
local h = require('helpers')

local csv = require('dblens.csv')
local import = require('dblens.import')
local sqlmod = require('dblens.sql')

local eq = h.eq

local DIALECT = sqlmod.dialects.sqlite
local TABLE = { name = 't', kind = 'table' }

local function options(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
    discovery = { auto = false },
  }, extra or {})
end

local function open_with_session(session_mod, spec, extra)
  local app = require('dblens.app')
  require('dblens.config').setup(options(extra))
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.session = h.fake_session(session_mod, spec, options(extra))
  state.session.catalog:set_relations(nil, { TABLE })
  state.session.catalog:set_part(TABLE, 'columns', {
    { name = 'id', type = 'int', notnull = true, pk = 1 },
    { name = 'note', type = 'text', notnull = false, pk = 0 },
  })
  state.session.catalog:set_part(TABLE, 'indexes', {})
  state.session.catalog:set_part(TABLE, 'constraints', {})
  return app, state
end

--- Write a CSV file the importer can be pointed at.
local function csv_file(text)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/in.csv'
  local file = assert(io.open(path, 'w'))
  file:write(text)
  file:close()
  return path
end

--- Drive the importer with a scripted answer to its file prompt, and collect what it said.
---@return string[] messages
local function import_from(state, relation, answer)
  local said = {}
  local input, notify = vim.ui.input, vim.notify
  vim.ui.input = function(_, on_input)
    on_input(answer)
  end
  vim.notify = function(message)
    said[#said + 1] = message
  end
  local ok, err = pcall(require('dblens.ui.importer').start, state, relation)
  vim.ui.input, vim.notify = input, notify
  assert(ok, tostring(err))
  return said
end

--- Answer the confirmation float with `y`, so the run proceeds without a keypress.
local function confirming(fn)
  local confirm = require('dblens.ui.confirm')
  local real = confirm.ask
  local shown = {}
  confirm.ask = function(_, opts, on_confirm)
    shown[#shown + 1] = opts
    on_confirm()
  end
  local ok, err = pcall(fn, shown)
  confirm.ask = real
  assert(ok, tostring(err))
  return shown
end

-- ---------------------------------------------------------------------------

describe('csv: reading a file to RFC 4180', function()
  it('reads plain records', function()
    eq(csv.parse('a,b\n1,2\n'), { { 'a', 'b' }, { '1', '2' } })
  end)

  it('keeps a comma, a quote and a newline inside a quoted value', function()
    local rows = csv.parse('a\n"x,y"\n"he said ""hi"""\n"line1\nline2"\n')
    eq(rows, { { 'a' }, { 'x,y' }, { 'he said "hi"' }, { 'line1\nline2' } })
  end)

  it('reads a record with no trailing newline', function()
    eq(csv.parse('a,b\n1,2'), { { 'a', 'b' }, { '1', '2' } })
  end)

  it('handles CRLF, and keeps a CR inside a quoted value', function()
    eq(csv.parse('a,b\r\n1,2\r\n'), { { 'a', 'b' }, { '1', '2' } })
    eq(csv.parse('a\r\n"x\r\ny"\r\n')[2][1], 'x\r\ny')
  end)

  it('strips a UTF-8 BOM rather than making it part of the first column name', function()
    eq(csv.parse('\239\187\191id\n1\n')[1][1], 'id')
  end)

  --- The one place quoting decides the VALUE, and what makes an export/import round trip keep
  --- NULL and the empty string apart.
  it('reads an unquoted empty field as NULL and a quoted one as the empty string', function()
    local rows = csv.parse('a,b\n,""\n')
    eq(rows[2][1], h.NULL)
    eq(rows[2][2], '')
  end)

  it('refuses an unterminated quote, naming the line', function()
    local rows, err = csv.parse('a\n"never closed\n')
    eq(rows, nil)
    eq(err:find('line 2', 1, true) ~= nil, true, { fail_reason = tostring(err) })
    eq(err:find('never closed', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('refuses text after a closing quote instead of guessing', function()
    local rows, err = csv.parse('a\n"x"junk\n')
    eq(rows, nil)
    eq(err:find('after a quoted value', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('refuses a quote inside an unquoted value', function()
    local rows, err = csv.parse('a\nx"y\n')
    eq(rows, nil)
    eq(err:find('unquoted', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('stops at the row cap rather than reading a huge file into memory', function()
    local rows, err = csv.parse('a\n1\n2\n3\n', { max_rows = 3 })
    eq(rows, nil)
    eq(err:find('more than 3 rows', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)
end)

describe('import: planning the INSERTs', function()
  local COLUMNS = { 'id', 'note' }

  it('maps the header to the table columns and builds one INSERT per row', function()
    local plan = assert(import.plan(TABLE, csv.parse('id,note\n1,a\n2,b\n'), COLUMNS, DIALECT))
    eq(plan.rows, 2)
    eq(plan.columns, { 'id', 'note' })
    eq(plan.changes[1].sql, [[INSERT INTO "t" ("id", "note") VALUES ('1', 'a')]])
    eq(plan.changes[2].sql, [[INSERT INTO "t" ("id", "note") VALUES ('2', 'b')]])
  end)

  it('follows the header order, not the table order', function()
    local plan = assert(import.plan(TABLE, csv.parse('note,id\na,1\n'), COLUMNS, DIALECT))
    eq(plan.changes[1].sql, [[INSERT INTO "t" ("note", "id") VALUES ('a', '1')]])
  end)

  it('matches a header whose case differs from the column', function()
    local plan = assert(import.plan(TABLE, csv.parse('ID,Note\n1,a\n'), COLUMNS, DIALECT))
    eq(plan.columns, { 'id', 'note' })
  end)

  it('writes an unquoted empty field as NULL and a quoted one as an empty string', function()
    local plan = assert(import.plan(TABLE, csv.parse('id,note\n1,\n2,""\n'), COLUMNS, DIALECT))
    eq(plan.changes[1].sql, [[INSERT INTO "t" ("id", "note") VALUES ('1', NULL)]])
    eq(plan.changes[2].sql, [[INSERT INTO "t" ("id", "note") VALUES ('2', '')]])
  end)

  it('names the columns the file does not set, rather than inventing values', function()
    local plan = assert(import.plan(TABLE, csv.parse('id\n1\n'), COLUMNS, DIALECT))
    eq(plan.unset, { 'note' })
    eq(plan.changes[1].sql, [[INSERT INTO "t" ("id") VALUES ('1')]])
  end)

  it('refuses a header naming a column the table does not have', function()
    local plan, err = import.plan(TABLE, csv.parse('id,nope\n1,x\n'), COLUMNS, DIALECT)
    eq(plan, nil)
    eq(err:find('`nope`', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('refuses a repeated header column', function()
    local plan, err = import.plan(TABLE, csv.parse('id,id\n1,2\n'), COLUMNS, DIALECT)
    eq(plan, nil)
    eq(err:find('twice', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('refuses a row that does not match the header, naming the row', function()
    local plan, err = import.plan(TABLE, csv.parse('id,note\n1,a\n2\n'), COLUMNS, DIALECT)
    eq(plan, nil)
    eq(err:find('row 3', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('refuses a header cell with no name', function()
    local plan, err = import.plan(TABLE, csv.parse('id,\n1,a\n'), COLUMNS, DIALECT)
    eq(plan, nil)
    eq(err:find('no name', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)

  it('refuses a file that is only a header', function()
    local plan, err = import.plan(TABLE, csv.parse('id,note\n'), COLUMNS, DIALECT)
    eq(plan, nil)
    eq(err:find('no data', 1, true) ~= nil, true, { fail_reason = tostring(err) })
  end)
end)

--- THE case. A cell written to break out of its literal has to arrive as the string it is.
describe('import: a hostile CSV value is data, not syntax', function()
  local PAYLOADS = {
    [[');  DROP TABLE t;--]],
    [[' OR '1'='1]],
    [[x'); DELETE FROM t WHERE 'a'='a]],
    'multi\nline\nvalue',
    [[back\slash]],
  }

  it('imports the payload as one INSERT that stores it, and nothing else', function()
    for _, payload in ipairs(PAYLOADS) do
      local text = ('id,note\n1,"%s"\n'):format(payload:gsub('"', '""'))
      local rows = assert(csv.parse(text))
      eq(rows[2][2], payload, { fail_reason = 'the parser mangled the payload' })

      local plan = assert(import.plan(TABLE, rows, { 'id', 'note' }, DIALECT))
      local statement = plan.changes[1].sql

      eq(#sqlmod.split(statement, DIALECT), 1, {
        fail_reason = 'the value stacked a second statement: ' .. statement,
      })
      local info = sqlmod.classify(statement, DIALECT)
      eq(info.verb, 'INSERT', { fail_reason = statement })
      eq(info.destructive, false, { fail_reason = 'the payload made the INSERT destructive' })
      -- The payload survives whole, escaped, as one literal.
      eq(statement:find(("'%s'"):format(payload:gsub("'", "''")), 1, true) ~= nil, true, {
        fail_reason = statement,
      })
    end
  end)

  it('quotes a header-driven identifier so it cannot escape its own position', function()
    local hostile = { 'id', 'a" , (SELECT 1)) --' }
    local text = 'id,"a"" , (SELECT 1)) --"\n1,x\n'
    local plan = assert(import.plan(TABLE, assert(csv.parse(text)), hostile, DIALECT))
    local statement = plan.changes[1].sql
    eq(#sqlmod.split(statement, DIALECT), 1, { fail_reason = statement })
    eq(statement:find('"a"" , (SELECT 1)) --"', 1, true) ~= nil, true, { fail_reason = statement })
  end)
end)

describe('import: the guards around the run', function()
  it('refuses a LOCKED connection, and never asks for a file', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod, { read_only = true })
      local asked = false
      local input = vim.ui.input
      vim.ui.input = function()
        asked = true
      end
      local said = {}
      local notify = vim.notify
      vim.notify = function(message)
        said[#said + 1] = message
      end

      require('dblens.ui.importer').start(state, TABLE)

      vim.ui.input, vim.notify = input, notify
      eq(asked, false, { fail_reason = 'a locked connection was asked for a file to import' })
      eq(#calls, 0, { fail_reason = 'a locked connection ran something' })
      local text = table.concat(said, '\n')
      eq(text:find('LOCKED', 1, true) ~= nil, true, { fail_reason = text })
      eq(text:find('DbLensWrite', 1, true) ~= nil, true, { fail_reason = text })
      app.close()
    end)
  end)

  it('refuses while another transaction is queued, rather than joining it', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      state.session.txn:begin()
      state.session.txn:add({ sql = 'UPDATE t SET note = 1', summary = 'x' })

      local said = import_from(state, TABLE, csv_file('id,note\n1,a\n'))

      eq(#calls, 0, { fail_reason = 'the import ran with a transaction already open' })
      eq(
        table.concat(said, '\n'):find('commit or roll back', 1, true) ~= nil,
        true,
        { fail_reason = table.concat(said, '\n') }
      )
      state.session.txn:reset()
      app.close()
    end)
  end)

  it('previews the mapping and the statements, and runs nothing until confirmed', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      local confirm = require('dblens.ui.confirm')
      local real, shown = confirm.ask, nil
      confirm.ask = function(_, opts)
        shown = opts
      end

      import_from(state, TABLE, csv_file('id,note\n1,a\n2,b\n'))

      confirm.ask = real
      eq(type(shown) == 'table', true, { fail_reason = 'no confirmation was shown' })
      eq(#calls, 0, { fail_reason = 'the import ran before it was confirmed' })
      -- Flattened rather than inspected: `vim.inspect` escapes the quotes in the SQL.
      local said_lines = {}
      for _, section in ipairs(shown.sections) do
        said_lines[#said_lines + 1] = section.heading
        vim.list_extend(said_lines, section.lines)
      end
      local text = table.concat(said_lines, '\n')
      eq(text:find('2 row(s) into t', 1, true) ~= nil, true, { fail_reason = text })
      eq(text:find('CSV column 1 -> id', 1, true) ~= nil, true, { fail_reason = text })
      eq(text:find('INSERT INTO "t"', 1, true) ~= nil, true, { fail_reason = text })
      eq(text:find('one transaction', 1, true) ~= nil, true, { fail_reason = text })
      app.close()
    end)
  end)

  it('runs the whole file as ONE transaction once confirmed', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      confirming(function()
        import_from(state, TABLE, csv_file('id,note\n1,a\n2,b\n'))
      end)

      -- One client call: the whole batch, framed as a transaction.
      local sent = calls[1] and calls[1].stdin or ''
      eq(sent:find('BEGIN', 1, true) ~= nil, true, { fail_reason = sent })
      eq(sent:find('COMMIT', 1, true) ~= nil, true, { fail_reason = sent })
      local _, inserts = sent:gsub('INSERT INTO', '')
      eq(inserts, 2, { fail_reason = sent })
      eq(state.session.txn:is_active(), false, { fail_reason = 'the queue outlived the import' })
      app.close()
    end)
  end)

  --- Never a partial import: the client aborts the batch at the failing row and the server rolls
  --- it back, and the message names the row rather than the raw client error.
  it('rolls the whole import back and names the row that failed', function()
    h.with_fake_exec(function()
      return {
        ok = false,
        code = 1,
        stderr = 'Error: near line 3: UNIQUE constraint failed: t.id',
      }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      local said
      confirming(function()
        said = import_from(state, TABLE, csv_file('id,note\n1,a\n2,b\n3,c\n'))
      end)

      eq(#calls, 1, { fail_reason = 'a failed import must not retry row by row' })
      local text = table.concat(said, '\n')
      eq(text:find('nothing was imported', 1, true) ~= nil, true, { fail_reason = text })
      eq(text:find('change 2 of 3', 1, true) ~= nil, true, { fail_reason = text })
      eq(state.session.txn:is_active(), false, {
        fail_reason = 'the failed import left its changes queued',
      })
      app.close()
    end)
  end)

  it('reports a malformed file and runs nothing', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      local said = import_from(state, TABLE, csv_file('id,note\n"unclosed,a\n'))
      eq(#calls, 0)
      eq(
        table.concat(said, '\n'):find('never closed', 1, true) ~= nil,
        true,
        { fail_reason = table.concat(said, '\n') }
      )
      app.close()
    end)
  end)

  it('refuses a file past the row cap, naming the option', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod, {}, { import = { max_rows = 2 } })
      local said = import_from(state, TABLE, csv_file('id,note\n1,a\n2,b\n3,c\n'))
      eq(#calls, 0)
      eq(
        table.concat(said, '\n'):find('import.max_rows', 1, true) ~= nil,
        true,
        { fail_reason = table.concat(said, '\n') }
      )
      app.close()
    end)
  end)

  it('refuses a file bigger than the byte cap without reading it', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod, {}, { import = { max_bytes = 8 } })
      local said = import_from(state, TABLE, csv_file('id,note\n1,aaaaaaaaaaaaaaaaaaa\n'))
      eq(#calls, 0)
      eq(
        table.concat(said, '\n'):find('import.max_bytes', 1, true) ~= nil,
        true,
        { fail_reason = table.concat(said, '\n') }
      )
      app.close()
    end)
  end)

  it('refuses a path that would be evaluated rather than opened', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      local said = import_from(state, TABLE, '/tmp/`whoami`.csv')
      eq(#calls, 0)
      eq(
        table.concat(said, '\n'):find('backtick', 1, true) ~= nil,
        true,
        { fail_reason = table.concat(said, '\n') }
      )
      app.close()
    end)
  end)
end)

--- sqlite, live. The round trip: a table with values that break naive quoting is exported to CSV,
--- imported into a fresh table by the real client, and the two are compared row for row.
describe('sqlite, live: a table exported to CSV imports back identical', function()
  local MiniTest = require('mini.test')
  local export = require('dblens.export')
  local protocol = require('dblens.protocol')

  local target, scratch = nil, nil
  local VALUES = {
    "O'Brien",
    'a,b "quoted"',
    'line1\nline2',
    'héllo 世界',
    [[');  DROP TABLE dest;--]],
    'NULL',
    '',
  }

  local function sqlite(db, sql, extra)
    local argv = { target.client, '-batch', '-bail' }
    vim.list_extend(argv, extra or {})
    argv[#argv + 1] = db
    return vim.system(argv, { stdin = sql }):wait(60000)
  end

  local function skip()
    if target then
      return false
    end
    MiniTest.add_note('sqlite3 is not installed; the live import round trip did not run')
    return true
  end

  before_each(function()
    target = h.live_file_client('sqlite')
    scratch = vim.fn.tempname()
    vim.fn.mkdir(scratch, 'p')
  end)

  after_each(function()
    if scratch then
      vim.fn.delete(scratch, 'rf')
    end
  end)

  it('imports every value as data, NULL included, and the payload row is a row', function()
    if skip() then
      return
    end
    local db = ('%s/round-trip.db'):format(scratch)
    local statements = {
      'CREATE TABLE src(id INTEGER PRIMARY KEY, v TEXT);',
      'CREATE TABLE dest(id INTEGER PRIMARY KEY, v TEXT);',
    }
    for index, value in ipairs(VALUES) do
      statements[#statements + 1] = ("INSERT INTO src VALUES (%d, '%s');"):format(
        index,
        value:gsub("'", "''")
      )
    end
    statements[#statements + 1] = ('INSERT INTO src VALUES (%d, NULL);'):format(#VALUES + 1)
    assert(sqlite(db, table.concat(statements, '\n')).code == 0, 'could not seed sqlite')

    -- Export through dblens's own CSV writer, from the rows the client prints.
    -- The NULL sentinel, so the dump tells SQL NULL from the empty string exactly as the record
    -- protocol dblens itself reads with does.
    local dumped = sqlite(
      db,
      'SELECT id, v FROM src ORDER BY id;',
      { '-csv', '-header', '-nullvalue', h.NULL_SENTINEL }
    )
    eq(dumped.code, 0, { fail_reason = tostring(dumped.stderr) })
    local decoded = protocol.decode_csv(dumped.stdout)
    local path = ('%s/src.csv'):format(scratch)
    local wrote, write_err =
      export.write({ columns = decoded.columns, rows = decoded.rows, malformed = 0 }, path, 'csv')
    eq(wrote, true, { fail_reason = tostring(write_err) })

    -- Import it into the empty table, exactly as the UI would: parse, plan, run the batch.
    local file = assert(io.open(path, 'r'))
    local text = file:read('*a')
    file:close()
    local rows = assert(csv.parse(text, { max_rows = 1000 }))
    local plan =
      assert(import.plan({ name = 'dest', kind = 'table' }, rows, { 'id', 'v' }, DIALECT))
    eq(plan.rows, #VALUES + 1)

    local batch = { 'BEGIN;' }
    for _, change in ipairs(plan.changes) do
      batch[#batch + 1] = change.sql .. ';'
    end
    batch[#batch + 1] = 'COMMIT;'
    local ran = sqlite(db, table.concat(batch, '\n'))
    eq(ran.code, 0, { fail_reason = 'the generated import failed: ' .. tostring(ran.stderr) })

    -- `typeof` is projected so NULL and the empty string cannot both read as empty.
    local query = 'SELECT id, typeof(v), v FROM %s ORDER BY id;'
    local before = sqlite(db, query:format('src'), { '-csv', '-header' })
    local after = sqlite(db, query:format('dest'), { '-csv', '-header' })
    eq(after.stdout, before.stdout, { fail_reason = 'the imported table differs from the source' })

    -- The payload row is a ROW: `dest` still exists and holds every value.
    local counted = sqlite(db, 'SELECT count(*) AS n FROM dest;', { '-csv', '-header' })
    eq(protocol.decode_csv(counted.stdout).rows[1][1], tostring(#VALUES + 1))
  end)
end)

--- postgres, live. The transactional claim, proved by a server that really rolls back: a good
--- file lands every row, and a file whose last row violates a constraint imports NOTHING.
describe('postgres, live: a failing row rolls the whole import back', function()
  local MiniTest = require('mini.test')
  local adapter = assert(require('dblens.adapters').get('postgres'))
  local loader = require('dblens.loader')
  local target = nil
  local RELATION = { schema = 'public', name = 'import_live', kind = 'table' }

  --- Send a statement over the adapter's own argv, with no gate in front of it.
  local function psql(statement)
    local spec = vim.tbl_extend('force', target.spec, { read_only = false })
    local command = adapter.command(spec, target.secret, 'records', target.clients)
    return vim.system(command.argv, { env = command.env, stdin = statement }):wait(60000)
  end

  local function rows_now()
    local out = psql('SELECT id, note FROM import_live ORDER BY id')
    if out.code ~= 0 then
      return 'gone: ' .. tostring(out.stderr)
    end
    local decoded = adapter.decode(out.stdout, {})
    local lines = {}
    for _, row in ipairs(decoded.rows) do
      lines[#lines + 1] = table.concat({ tostring(row[1]), tostring(row[2]) }, '|')
    end
    return table.concat(lines, '\n')
  end

  local function skip()
    if target then
      return false
    end
    MiniTest.add_note(
      'no postgres server (set DBLENS_TEST_POSTGRES_PORT); the live import did not run'
    )
    return true
  end

  before_each(function()
    target = h.live_target('postgres')
  end)

  --- A UI over a REAL writable session, with the table's columns loaded.
  local function live_ui()
    local app = require('dblens.app')
    require('dblens.config').setup(
      vim.tbl_deep_extend('force', options(), { clients = target.clients })
    )
    app.open()
    local state = assert(app.state(), 'app.open left no state')
    local session = assert(
      require('dblens.session').new(
        vim.tbl_extend('force', target.spec, { read_only = false }),
        state.options
      )
    )
    session.secret = target.secret
    session.connected = true
    state.session = session

    local done = false
    loader.relations(session, 'public', function(err)
      assert(not err, tostring(err))
      done = true
    end)
    assert(
      vim.wait(60000, function()
        return done
      end),
      'the live client never listed the schema'
    )
    return app, state
  end

  --- Run the importer end to end, answering its prompt and its confirmation.
  ---
  --- The hooks stay installed across the WAIT: every step here is a real client call, so the
  --- messages the flow ends with arrive long after `start` has returned.
  ---@return string[] messages
  local function run_import(state, text)
    local path = csv_file(text)
    local said = {}
    local input, notify = vim.ui.input, vim.notify
    local confirm = require('dblens.ui.confirm')
    local ask = confirm.ask
    vim.ui.input = function(_, on_input)
      on_input(path)
    end
    vim.notify = function(message)
      said[#said + 1] = message
    end
    confirm.ask = function(_, _, on_confirm)
      on_confirm()
    end
    local ok, err = pcall(require('dblens.ui.importer').start, state, RELATION)
    local finished = ok and vim.wait(60000, function()
      return #said > 0
    end)
    vim.ui.input, vim.notify, confirm.ask = input, notify, ask
    assert(ok, tostring(err))
    assert(finished, 'the live import never reported an outcome')
    return said
  end

  it('imports every row, then imports nothing at all when one row fails', function()
    if skip() then
      return
    end
    local seeded = psql([[
DROP TABLE IF EXISTS import_live;
CREATE TABLE import_live(id int PRIMARY KEY, note text);
]])
    eq(seeded.code, 0, { fail_reason = tostring(seeded.stderr) })

    local app, state = live_ui()
    -- A payload value and a NULL, so the live path carries the same data the unit cases do.
    local hostile = table.concat({
      'id,note',
      [[1,"'); DROP TABLE import_live;--"]],
      '2,',
      '3,"a,b"',
      '',
    }, '\n')
    local said = run_import(state, hostile)
    eq(
      table.concat(said, '\n'):find('imported 3 row', 1, true) ~= nil,
      true,
      { fail_reason = table.concat(said, '\n') }
    )
    local landed = rows_now()
    eq(landed:find('DROP TABLE import_live', 1, true) ~= nil, true, { fail_reason = landed })
    eq(
      select(2, landed:gsub('\n', '')),
      2,
      { fail_reason = 'three rows should have landed: ' .. landed }
    )

    -- Now a file whose LAST row collides with the primary key: nothing may land.
    local before = rows_now()
    local failed = run_import(state, 'id,note\n4,four\n5,five\n1,collides\n')
    local text = table.concat(failed, '\n')
    eq(text:find('nothing was imported', 1, true) ~= nil, true, { fail_reason = text })
    eq(text:find('change 3 of 3', 1, true) ~= nil, true, { fail_reason = text })
    eq(rows_now(), before, { fail_reason = 'a failed import left rows behind' })
    eq(state.session.txn:is_active(), false, { fail_reason = 'the queue outlived the failure' })
    app.close()
  end)
end)
