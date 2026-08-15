--- The three engines added after the security model was already settled: mariadb, duckdb and
--- mssql. What matters here is that each one is held to the SAME contract as the first three --
--- argv that never carries the secret, decoding that cannot confuse NULL with data, quoting a
--- hostile object name cannot escape -- and that the ONE of them whose LOCKED mode is weaker says
--- so in the one place the UI reads.
---
--- The live cases are env-gated exactly like the existing ones: `DBLENS_TEST_MARIADB_PORT` /
--- `DBLENS_TEST_MSSQL_PORT` (plus `_HOST`, `_USER`, `_PASSWORD`, `_DB`, `_CLIENT`) turn them on,
--- and `DBLENS_TEST_DUCKDB_CLIENT` points at a `duckdb` binary.
local h = require('helpers')
local adapters = require('dblens.adapters')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local eq = h.eq
local SECRET = 'hunter2-s3cr3t'

--- A relation whose name and schema both fight the quoting.
local WEIRD = { schema = 'we.ird', name = 'my "weird" tbl', kind = 'table' }

local function get(kind)
  local adapter, err = adapters.get(kind)
  assert(adapter, tostring(err))
  return adapter
end

describe('mariadb.command', function()
  local mariadb = get('mariadb')

  it('drives the `mariadb` binary, not `mysql`', function()
    local cmd = mariadb.command({ database = 'app' }, nil, 'records', h.CLIENTS)
    eq(cmd.argv[1], 'mariadb')
    eq(h.has(cmd.argv, '--xml'), true)
    eq(cmd.argv[#cmd.argv], 'app')
  end)

  it('honours a configured client path', function()
    local clients = vim.tbl_extend('force', h.CLIENTS, { mariadb = '/opt/mariadb/bin/mariadb' })
    eq(
      mariadb.command({ database = 'app' }, nil, 'records', clients).argv[1],
      '/opt/mariadb/bin/mariadb'
    )
  end)

  it('opens a read-only session and leaves a writable one alone', function()
    local switch = '--init-command=SET SESSION TRANSACTION READ ONLY'
    local locked =
      mariadb.command({ database = 'app', read_only = true }, nil, 'records', h.CLIENTS)
    eq(h.has(locked.argv, switch), true)
    local open = mariadb.command({ database = 'app', read_only = false }, nil, 'records', h.CLIENTS)
    eq(h.has(open.argv, switch), false)
  end)

  it('blocks LOAD DATA LOCAL INFILE whatever the mode', function()
    for _, read_only in ipairs({ true, false }) do
      local cmd =
        mariadb.command({ database = 'app', read_only = read_only }, nil, 'records', h.CLIENTS)
      eq(h.has(cmd.argv, '--local-infile=0'), true)
    end
  end)

  it('never puts the password in argv', function()
    local cmd = mariadb.command({ database = 'app', user = 'u' }, SECRET, 'records', h.CLIENTS)
    eq(h.leaks(cmd.argv, SECRET), false)
    eq(cmd.env.MYSQL_PWD, SECRET)
  end)

  it('rejects a spec with no database, and a non-numeric port', function()
    eq(mariadb.validate({}), 'mariadb connection needs a `database`')
    eq(mariadb.validate({ database = 'app', port = '3306' }), 'mariadb `port` must be a number')
    eq(mariadb.validate({ database = 'app', port = 3306 }), nil)
  end)
end)

--- MariaDB's `--xml` is byte-identical in shape to MySQL's, so the adapter shares the decoder
--- rather than copying it. These cases are the hazards that decoder exists for, re-run through
--- the mariadb adapter so a future divergence is caught here rather than in a user's grid.
describe('mariadb.decode', function()
  local mariadb = get('mariadb')

  it('is the mysql decoder, deliberately', function()
    eq(mariadb.decode == get('mysql').decode, true)
  end)

  it('keeps a mid-row NULL in its own column', function()
    local xml = [[<?xml version="1.0"?>
<resultset statement="SELECT">
  <row>
	<field name="a">1</field>
	<field name="b" xsi:nil="true" />
	<field name="c">3</field>
  </row>
</resultset>]]
    local decoded = mariadb.decode(xml, {})
    eq(decoded.columns, { 'a', 'b', 'c' })
    eq(decoded.rows[1], { '1', h.NULL, '3' })
    eq(decoded.malformed, 0)
  end)

  it("tells SQL NULL from the four-character string 'NULL'", function()
    local xml = [[<resultset>
  <row><field name="a" xsi:nil="true" /><field name="b">NULL</field></row>
</resultset>]]
    eq(get('mariadb').decode(xml, {}).rows[1], { h.NULL, 'NULL' })
  end)

  it('unescapes entities and keeps separator bytes as data', function()
    local xml = (
      '<resultset><row><field name="a">x&lt;y&amp;z</field>'
      .. '<field name="b">%s%s</field></row></resultset>'
    ):format(protocol.FIELD_SEP, protocol.RECORD_SEP)
    eq(
      get('mariadb').decode(xml, {}).rows[1],
      { 'x<y&z', protocol.FIELD_SEP .. protocol.RECORD_SEP }
    )
  end)

  it('decodes the first result set only', function()
    local xml = '<resultset><row><field name="a">1</field></row></resultset>'
      .. '<resultset><row><field name="z">9</field></row></resultset>'
    local decoded = get('mariadb').decode(xml, {})
    eq(decoded.columns, { 'a' })
    eq(#decoded.rows, 1)
  end)
end)

describe('mariadb statement builders', function()
  local mariadb = get('mariadb')

  it('shares the mysql builders, dialect included', function()
    eq(mariadb.sql == get('mysql').sql, true)
    eq(mariadb.dialect == sql.dialects.mysql, true)
  end)

  it('quotes a hostile relation name so it cannot escape its delimiter', function()
    local page = mariadb.sql.page(WEIRD, { limit = 10, offset = 0 })
    eq(page:find('`we.ird`.`my "weird" tbl`', 1, true) ~= nil, true, { fail_reason = page })
  end)
end)

describe('duckdb.command', function()
  local duckdb = get('duckdb')

  it('builds the record protocol explicitly rather than trusting -ascii', function()
    local cmd = duckdb.command({ path = '/tmp/x.duckdb' }, nil, 'records', h.CLIENTS)
    eq(cmd.argv[1], 'duckdb')
    eq(h.flag_value(cmd.argv, '-separator'), protocol.FIELD_SEP)
    eq(h.flag_value(cmd.argv, '-newline'), protocol.RECORD_SEP)
    eq(h.flag_value(cmd.argv, '-nullvalue'), protocol.NULL_SENTINEL)
    eq(h.has(cmd.argv, '-list'), true)
    eq(h.has(cmd.argv, '-header'), true)
    eq(h.has(cmd.argv, '-ascii'), false, {
      fail_reason = 'duckdb -ascii emits \\n for BOTH separators, which cannot be decoded',
    })
  end)

  it('stops at the first error, so a batch cannot commit in part', function()
    local cmd = duckdb.command({ path = '/tmp/x.duckdb' }, nil, 'records', h.CLIENTS)
    eq(h.has(cmd.argv, '-bail'), true)
  end)

  it('passes the database file last, expanded', function()
    local cmd = duckdb.command({ path = '/tmp/x.duckdb' }, nil, 'raw', h.CLIENTS)
    eq(cmd.argv[#cmd.argv], '/tmp/x.duckdb')
  end)

  it('has no secret to leak, and sets no environment', function()
    eq(duckdb.command({ path = '/tmp/x.duckdb' }, SECRET, 'records', h.CLIENTS).env, nil)
  end)

  it('rejects a spec with no path, and a path that would be evaluated', function()
    eq(duckdb.validate({}), 'duckdb connection needs a `path`')
    eq(duckdb.validate({ path = '' }), 'duckdb connection needs a `path`')
    eq(duckdb.validate({ path = '/tmp/x.duckdb' }), nil)
    eq(type(duckdb.validate({ name = 'x', path = '/tmp/`id`.duckdb' })), 'string')
  end)
end)

describe('duckdb decoding and statement builders', function()
  local duckdb = get('duckdb')

  it('decodes the shared record protocol', function()
    local wire = h.wire({ h.record('a', 'b'), h.record('1', h.NULL_SENTINEL) })
    local decoded = duckdb.decode(wire, {})
    eq(decoded.columns, { 'a', 'b' })
    eq(decoded.rows[1], { '1', h.NULL })
  end)

  it('quotes a hostile relation name with double quotes', function()
    local page = duckdb.sql.page(WEIRD, { limit = 5, offset = 10 })
    eq(page:find('"we.ird"."my ""weird"" tbl"', 1, true) ~= nil, true, { fail_reason = page })
    eq(page:find('LIMIT 5 OFFSET 10', 1, true) ~= nil, true)
  end)

  it('narrows the schema list to the current database', function()
    local schemas = duckdb.sql.schemas()
    eq(schemas:find('current_database()', 1, true) ~= nil, true, {
      fail_reason = 'duckdb lists a `main` per attached catalog; the tree must show one',
    })
  end)

  --- duckdb prints nothing at all for a DML statement and has no `changes()`, so the honest
  --- answer is no count -- not a fabricated zero.
  it('reports no affected-row count rather than a wrong one', function()
    eq(duckdb.sql.affected(), nil)
  end)

  it('raises from the row guard so `-bail` aborts the batch', function()
    local guard = duckdb.sql.assert_one('SELECT count(*) FROM t')
    eq(guard:find('error(', 1, true) ~= nil, true, { fail_reason = guard })
  end)
end)

describe('mssql.command', function()
  local mssql = get('mssql')

  --- Each of these was chosen against live behaviour, and dropping one is a real regression:
  --- without `-b` a failed statement exits 0, without `-r1` errors land in the result stream,
  --- without `-k1` a value holding a control byte splits the record, without `-X1` a `:!!` line
  --- runs a shell command on this machine.
  it('passes the four flags that are load-bearing', function()
    local cmd = mssql.command({ database = 'app' }, nil, 'records', h.CLIENTS)
    for _, flag in ipairs({ '-b', '-r1', '-k1', '-X1', '-I' }) do
      eq(h.has(cmd.argv, flag), true, { fail_reason = 'missing ' .. flag })
    end
  end)

  it('separates fields with the protocol separator in records mode', function()
    local cmd = mssql.command({ database = 'app' }, nil, 'records', h.CLIENTS)
    eq(h.flag_value(cmd.argv, '-s'), protocol.FIELD_SEP)
  end)

  it('addresses the server as host and port, never as a connection string', function()
    local cmd =
      mssql.command({ database = 'app', host = 'db1', port = 1444 }, nil, 'raw', h.CLIENTS)
    eq(h.flag_value(cmd.argv, '-S'), 'tcp:db1,1444')
    eq(h.flag_value(cmd.argv, '-d'), 'app')
  end)

  it('trusts the server certificate only when the spec says to', function()
    eq(h.has(mssql.command({ database = 'app' }, nil, 'raw', h.CLIENTS).argv, '-C'), false)
    local trusting =
      mssql.command({ database = 'app', trust_server_certificate = true }, nil, 'raw', h.CLIENTS)
    eq(h.has(trusting.argv, '-C'), true)
  end)

  it('never puts the password in argv', function()
    local cmd = mssql.command({ database = 'app', user = 'sa' }, SECRET, 'records', h.CLIENTS)
    eq(h.leaks(cmd.argv, SECRET), false)
    eq(cmd.env.SQLCMDPASSWORD, SECRET)
  end)

  it('refuses a host or database that is really a connection string', function()
    eq(type(mssql.validate({ database = 'app', host = 'db1,1433' })), 'string')
    eq(type(mssql.validate({ database = 'app', host = 'srv;Trusted_Connection=yes' })), 'string')
    eq(type(mssql.validate({ database = 'app;User Id=sa' })), 'string')
    eq(mssql.validate({ database = 'app', host = 'db1', port = 1433 }), nil)
    eq(mssql.validate({}), 'mssql connection needs a `database`')
  end)
end)

--- sqlcmd's text output is the weakest wire format dblens decodes, and the decoder's job is to
--- fail visibly rather than quietly: the dashed rule and the row-count message are not rows, and
--- the NULL ambiguity is real and documented rather than papered over.
describe('mssql.decode', function()
  local mssql = get('mssql')
  local FS = protocol.FIELD_SEP

  local function output(lines)
    return table.concat(lines, '\n') .. '\n'
  end

  it('drops the dashed rule and the row-count message', function()
    local decoded = mssql.decode(output({
      'a' .. FS .. 'b',
      '-' .. FS .. '---',
      '1' .. FS .. 'x',
      '2' .. FS .. 'y',
      '',
      '(2 rows affected)',
    }))
    eq(decoded.columns, { 'a', 'b' })
    eq(decoded.rows, { { '1', 'x' }, { '2', 'y' } })
    eq(decoded.malformed, 0)
  end)

  it('keeps the headers of a zero-row result', function()
    local decoded =
      mssql.decode(output({ 'a' .. FS .. 'b', '-' .. FS .. '-', '', '(0 rows affected)' }))
    eq(decoded.columns, { 'a', 'b' })
    eq(#decoded.rows, 0)
  end)

  it('decodes the first result set only', function()
    local decoded = mssql.decode(output({
      'a',
      '-',
      '1',
      '',
      '(1 rows affected)',
      'z',
      '-',
      '9',
      '',
      '(1 rows affected)',
    }))
    eq(decoded.columns, { 'a' })
    eq(decoded.rows, { { '1' } })
  end)

  it('pads a short row and counts it as malformed rather than dropping it', function()
    local decoded = mssql.decode(output({ 'a' .. FS .. 'b', '-' .. FS .. '-', '1' }))
    eq(decoded.rows, { { '1', h.NULL } })
    eq(decoded.malformed, 1)
  end)

  it('keeps a blank line that is a row, not a terminator', function()
    local decoded = mssql.decode(output({ 'a', '-', '1', '', '2', '', '(3 rows affected)' }))
    eq(decoded.rows, { { '1' }, { '' }, { '2' } })
  end)

  it('survives CRLF and empty output', function()
    eq(
      mssql.decode('a' .. FS .. 'b\r\n-' .. FS .. '-\r\n1' .. FS .. '2\r\n').rows,
      { { '1', '2' } }
    )
    eq(mssql.decode('').rows, {})
    eq(mssql.decode('').columns, {})
  end)

  --- A message or audit column can hold the exact text sqlcmd ends a result set with. Matching on
  --- content stopped decoding there: the row and everything after it vanished, with no error and
  --- `malformed = 0` — an empty grid for a table that has rows. Position is what decides now.
  it('keeps a row whose value reads like the row-count line', function()
    local decoded = mssql.decode(output({
      'msg',
      '---',
      '(3 rows affected)',
      'real row',
      '',
      '(2 rows affected)',
    }))
    eq(decoded.columns, { 'msg' })
    eq(decoded.rows, { { '(3 rows affected)' }, { 'real row' } })
    eq(decoded.malformed, 0)
  end)

  --- THE DOCUMENTED LIMITATION, pinned so nobody later claims mssql decodes NULL exactly. sqlcmd
  --- has no null-marker option, so a real NULL and the string 'NULL' arrive as the same bytes.
  it('cannot tell SQL NULL from the string `NULL`, and this is the case that says so', function()
    local decoded =
      mssql.decode(output({ 'a' .. FS .. 'b', '-' .. FS .. '-', 'NULL' .. FS .. 'NULL' }))
    eq(decoded.rows[1], { h.NULL, h.NULL }, {
      fail_reason = 'both cells decode as NULL; the string is the one that loses',
    })
  end)
end)

describe('mssql statement builders', function()
  local mssql = get('mssql')

  it('pages with OFFSET/FETCH, which T-SQL requires an ORDER BY for', function()
    local page = mssql.sql.page({ schema = 'dbo', name = 't' }, { limit = 100, offset = 200 })
    eq(page:find('ORDER BY (SELECT NULL)', 1, true) ~= nil, true, { fail_reason = page })
    eq(page:find('OFFSET 200 ROWS FETCH NEXT 100 ROWS ONLY', 1, true) ~= nil, true)
    eq(page:find('LIMIT', 1, true), nil, { fail_reason = 'T-SQL has no LIMIT: ' .. page })
  end)

  it('orders by the requested column when there is one', function()
    local page = mssql.sql.page(
      { schema = 'dbo', name = 't' },
      { limit = 10, offset = 0, order_by = { column = 'created at', desc = true } }
    )
    eq(page:find('ORDER BY "created at" DESC', 1, true) ~= nil, true, { fail_reason = page })
  end)

  it('quotes a hostile relation name so it cannot escape its delimiter', function()
    local page = mssql.sql.page(WEIRD, { limit = 5, offset = 0 })
    eq(page:find('"we.ird"."my ""weird"" tbl"', 1, true) ~= nil, true, { fail_reason = page })
  end)

  it('refuses a page whose filter did not pass the predicate check', function()
    h.expect_error(function()
      mssql.sql.page({ schema = 'dbo', name = 't' }, { limit = 5, offset = 0, where = 'a = 1; --' })
    end)
  end)

  --- `BEGIN;` is a BLOCK in T-SQL, not a transaction: a commit batch framed with it would run
  --- unprotected and every statement would land on its own.
  it('frames the commit batch with a real transaction and XACT_ABORT', function()
    local frame = mssql.sql.batch_frame()
    eq(frame.open:find('BEGIN TRANSACTION', 1, true) ~= nil, true)
    eq(frame.open:find('SET XACT_ABORT ON', 1, true) ~= nil, true)
    eq(frame.close, 'COMMIT TRANSACTION;')
  end)

  it('guards a queued change with THROW, which aborts the batch', function()
    local guard = mssql.sql.assert_one('SELECT count(*) FROM t')
    eq(guard:find('THROW', 1, true) ~= nil, true, { fail_reason = guard })
  end)

  it('reads the affected count in the same invocation', function()
    eq(mssql.sql.affected(), 'SELECT @@ROWCOUNT AS affected')
  end)

  --- A SQL Server plan needs its own batch, and dblens sends one statement per invocation. Saying
  --- so in `caps` is what keeps the UI from offering it; the builder fails loudly as a backstop.
  it('declares that it has no EXPLAIN, and refuses to invent one', function()
    eq(mssql.caps.explain, false)
    eq(mssql.caps.explain_analyze, false)
    h.expect_error(function()
      mssql.sql.explain('SELECT 1', false)
    end)
  end)
end)

describe('exec: the line sqlcmd blamed', function()
  local exec = require('dblens.exec')

  it('reads the line out of a `Msg ...` header', function()
    local stderr = 'Msg 208, Level 16, State 1, Server host, Line 4\nInvalid object name.'
    eq(exec.error_line(stderr), 4)
  end)

  it('still reads the other clients', function()
    eq(exec.error_line('Error: near line 3: no such table'), 3)
    eq(exec.error_line('psql:<stdin>:7: ERROR: boom'), 7)
    eq(exec.error_line('ERROR 1064 (42000) at line 2: You have an error'), 2)
  end)
end)

--- Live, MariaDB. The unit cases above assert the argv; this asserts the SERVER answers the way
--- the adapter's comments claim, which is the only thing that makes them true.
describe('mariadb, live: the adapter really drives a MariaDB server', function()
  local mariadb = get('mariadb')
  local target = nil

  local function send(read_only, statement)
    local spec = vim.tbl_extend('force', target.spec, { read_only = read_only })
    local command = mariadb.command(spec, target.secret, 'records', target.clients)
    local stdin = read_only and mariadb.read_only_script(statement) or statement
    return vim.system(command.argv, { env = command.env, stdin = stdin }):wait(60000)
  end

  local function skip()
    if target then
      return false
    end
    MiniTest.add_note(
      'no mariadb server (set DBLENS_TEST_MARIADB_PORT); the live proof did not run'
    )
    return true
  end

  before_each(function()
    target = h.live_target('mariadb')
  end)

  it('decodes a real result, NULLs and entities included', function()
    if skip() then
      return
    end
    local out = send(true, "SELECT 1 AS a, NULL AS b, 'NULL' AS c, 'x<y&z' AS d")
    eq(out.code, 0, { fail_reason = tostring(out.stderr) })
    local decoded = mariadb.decode(out.stdout, {})
    eq(decoded.columns, { 'a', 'b', 'c', 'd' })
    eq(decoded.rows[1], { '1', h.NULL, 'NULL', 'x<y&z' })
    eq(decoded.malformed, 0)
  end)

  --- THE CASE THE WRAP ALONE DOES NOT COVER. Verified on 11.8.8 that inside a bare
  --- `START TRANSACTION READ ONLY` a DROP TABLE SUCCEEDS -- DDL commits the transaction
  --- implicitly. The session switch in `command` is what refuses it, and this proves it does.
  it('refuses DDL on a locked connection, which needs the session switch', function()
    if skip() then
      return
    end
    local seeded = send(false, 'DROP TABLE IF EXISTS ddl_victim; CREATE TABLE ddl_victim(a int);')
    eq(seeded.code, 0, { fail_reason = tostring(seeded.stderr) })
    for _, statement in ipairs({
      'DROP TABLE ddl_victim',
      'ALTER TABLE ddl_victim ADD COLUMN b int',
    }) do
      local out = send(true, statement)
      eq(out.code ~= 0, true, { fail_reason = ('`%s` was allowed while locked'):format(statement) })
    end
    local still_there = send(false, 'SELECT count(*) AS n FROM ddl_victim')
    eq(still_there.code, 0, { fail_reason = 'the locked DDL took effect anyway' })
  end)
end)

--- Live, SQL Server. These cases exist to prove the HONEST claims, including the negative ones:
--- the engine does not refuse the write, so nothing but the gate does.
describe('mssql, live: what the server does and does not refuse', function()
  local mssql = get('mssql')
  local target = nil

  local function send(read_only, statement)
    local spec = vim.tbl_extend('force', target.spec, { read_only = read_only })
    local command = mssql.command(spec, target.secret, 'records', target.clients)
    local stdin = read_only and mssql.read_only_script(statement) or statement
    return vim.system(command.argv, { env = command.env, stdin = stdin }):wait(60000)
  end

  local function rows_in(table_name)
    local out = send(false, ('SELECT count(*) AS n FROM %s'):format(table_name))
    if out.code ~= 0 then
      return 'gone'
    end
    local first = mssql.decode(out.stdout, {}).rows[1]
    return first and tostring(first[1]) or 'none'
  end

  local function skip()
    if target then
      return false
    end
    MiniTest.add_note('no mssql server (set DBLENS_TEST_MSSQL_PORT); the live proof did not run')
    return true
  end

  before_each(function()
    target = h.live_target('mssql')
    if target then
      send(
        false,
        "IF OBJECT_ID('victim') IS NOT NULL DROP TABLE victim;\n"
          .. 'CREATE TABLE victim(a int);\nINSERT INTO victim VALUES (1);'
      )
    end
  end)

  it('decodes a real result through the adapter', function()
    if skip() then
      return
    end
    local out = send(true, "SELECT 1 AS a, 'two' AS b")
    eq(out.code, 0, { fail_reason = tostring(out.stderr) })
    local decoded = mssql.decode(out.stdout, {})
    eq(decoded.columns, { 'a', 'b' })
    eq(decoded.rows, { { '1', 'two' } })
  end)

  --- THE HONEST NEGATIVE. `-K ReadOnly` is on this connection and the INSERT still lands, which
  --- is why mssql's enforcement is declared `classifier` / `best-effort`. If a future SQL Server
  --- ever did refuse this, this case would fail and the declaration could be revisited.
  it('does NOT refuse a write on a read-only connection: the flag enforces nothing', function()
    if skip() then
      return
    end
    local spec = vim.tbl_extend('force', target.spec, { read_only = true })
    local command = mssql.command(spec, target.secret, 'records', target.clients)
    eq(h.has(command.argv, 'ReadOnly'), true)
    local before = rows_in('victim')
    -- Sent bare, WITHOUT the rollback wrap, so what is measured is the connection alone.
    local out = vim
      .system(command.argv, {
        env = command.env,
        stdin = 'INSERT INTO victim VALUES (42)',
      })
      :wait(60000)
    eq(out.code, 0, { fail_reason = tostring(out.stderr) })
    h.neq(rows_in('victim'), before, {
      fail_reason = 'the write was refused, so mssql may have gained a read-only connection mode',
    })
  end)

  --- T-SQL NEEDS NO SEPARATOR. This is what makes `single_statement_problem` insufficient here,
  --- and it is measured rather than assumed.
  it('runs two statements that are separated only by a space', function()
    if skip() then
      return
    end
    local before = rows_in('victim')
    local out = send(false, 'SELECT 1 INSERT INTO victim VALUES (7)')
    eq(out.code, 0, { fail_reason = tostring(out.stderr) })
    h.neq(rows_in('victim'), before, {
      fail_reason = 'T-SQL no longer juxtaposes statements; the dialect flag could be revisited',
    })
    eq(sql.single_statement_problem('SELECT 1 INSERT INTO victim VALUES (7)'), nil, {
      fail_reason = 'the framing rule cannot see this, which is why the classifier must',
    })
  end)

  --- The net under the classifier: a write that got past it is undone. Not a guarantee -- sqlcmd
  --- still exits 0 -- but the database does not change.
  it('rolls back a write that reaches the server inside the locked wrap', function()
    if skip() then
      return
    end
    local before = rows_in('victim')
    local out = send(true, 'INSERT INTO victim VALUES (99)')
    eq(out.code, 0, { fail_reason = tostring(out.stderr) })
    eq(rows_in('victim'), before, { fail_reason = 'the locked wrap committed a write' })
    local dropped = send(true, 'DROP TABLE victim')
    eq(dropped.code, 0, { fail_reason = tostring(dropped.stderr) })
    h.neq(rows_in('victim'), 'gone', { fail_reason = 'the locked wrap committed a DROP TABLE' })
  end)

  --- `GO` runs what follows as its OWN batch, which is why the gate refuses it: the statement
  --- after it is a second statement that no framing rule sees. Sent deliberately past the gate.
  it('runs the statement after a `GO` as its own batch', function()
    if skip() then
      return
    end
    local before = rows_in('victim')
    local out = send(false, 'SELECT 1\nGO\nINSERT INTO victim VALUES (77)')
    eq(out.code, 0, { fail_reason = tostring(out.stderr) })
    h.neq(rows_in('victim'), before, {
      fail_reason = '`GO` no longer starts a new batch; the client-command refusal could be revisited',
    })
  end)

  --- WHERE THE NET ENDS, measured rather than assumed. A `GO` alone does not escape the locked
  --- wrap -- the transaction survives the batch boundary on the same connection, so the trailing
  --- ROLLBACK still undoes the write. Adding a juxtaposed `COMMIT TRANSACTION` DOES escape it,
  --- and the row lands. That is the case that makes the wrap defence in depth rather than a
  --- guarantee: what refuses this payload is the gate (`GO` is a client command, and `COMMIT` is
  --- a write verb anywhere on T-SQL), and nothing else.
  it('is escaped by a payload that commits inside a second batch', function()
    if skip() then
      return
    end
    local survives = rows_in('victim')
    local wrapped = send(true, 'SELECT 1\nGO\nINSERT INTO victim VALUES (88)')
    eq(wrapped.code, 0, { fail_reason = tostring(wrapped.stderr) })
    eq(rows_in('victim'), survives, {
      fail_reason = 'the transaction no longer spans the `GO`; the wrap covers less than believed',
    })

    local escaped = send(true, 'SELECT 1\nGO\nINSERT INTO victim VALUES (99) COMMIT TRANSACTION')
    h.neq(rows_in('victim'), survives, {
      fail_reason = 'the rollback wrap held; if it now does, mssql could claim more than it does',
    })
    -- The row lands, and the run now SAYS SO. The wrap ends by checking the transaction is still
    -- open, so a payload that commits it away fails the batch instead of exiting 0 on a write
    -- dblens would otherwise have reported as a successful read.
    h.neq(escaped.code, 0, {
      fail_reason = 'a committed-away wrap must not report success: ' .. tostring(escaped.stderr),
    })
    eq(escaped.stderr:find('committed away', 1, true) ~= nil, true, {
      fail_reason = 'the failure must name the cause: ' .. tostring(escaped.stderr),
    })

    -- And the gate is what actually stops it, on both counts.
    local session = h.fake_session(require('dblens.session'), {
      kind = 'mssql',
      database = 'app',
      read_only = true,
    })
    eq(
      type(session:gate('SELECT 1\nGO\nINSERT INTO victim VALUES (99) COMMIT TRANSACTION')),
      'string'
    )
  end)

  it('reports the batch line a failed statement came from', function()
    if skip() then
      return
    end
    local out = send(false, 'SELECT 1;\nSELECT * FROM no_such_table;')
    eq(out.code ~= 0, true)
    eq(require('dblens.exec').error_line(out.stderr), 2, { fail_reason = tostring(out.stderr) })
  end)
end)
