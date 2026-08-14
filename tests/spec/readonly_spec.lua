--- Read-only is a SERVER guarantee, and this spec proves it the only way that means anything:
--- by sending a write to a real database over a real locked connection and observing that
--- nothing changed.
---
--- Three adversarial reviews defeated the Lua classifier — nested block comments, MySQL
--- executable comments, backslash escaping under NO_BACKSLASH_ESCAPES, client meta-commands —
--- because dblens's lexer and the server's parse differently and every divergence is a bypass.
--- So the cases below DELIBERATELY skip `Session:gate`: a test that asks the classifier first
--- proves nothing about what protects a user from the divergence nobody has found yet.
---
--- The postgres/mysql cases need a server. Point them at one with
--- `DBLENS_TEST_POSTGRES_PORT` / `DBLENS_TEST_MYSQL_PORT` (plus `_HOST`, `_USER`, `_PASSWORD`,
--- `_DB`, `_CLIENT`); with none set they add a note and skip, exactly like the sqlite cases do
--- when `sqlite3` is missing.
local h = require('helpers')
local sql = require('dblens.sql')

local eq = h.eq
local CLIENTS = { sqlite = 'sqlite3', postgres = 'psql', mysql = 'mysql' }

local function get(kind)
  local adapter, err = require('dblens.adapters').get(kind)
  assert(adapter, tostring(err))
  return adapter
end

--- What each adapter must put on the wire to make the SERVER enforce read-only.
local MECHANISM = {
  sqlite = {
    spec = { kind = 'sqlite', path = '/tmp/dblens-ro.db' },
    where = 'argv',
    switch = '-readonly',
  },
  postgres = {
    spec = { kind = 'postgres', database = 'app' },
    where = 'env',
    switch = 'PGOPTIONS=-c default_transaction_read_only=on',
  },
  mysql = {
    spec = { kind = 'mysql', database = 'app' },
    where = 'argv',
    switch = '--init-command=SET SESSION TRANSACTION READ ONLY',
  },
}

local function flatten(command)
  local parts = vim.deepcopy(command.argv)
  for name, value in pairs(command.env or {}) do
    parts[#parts + 1] = name .. '=' .. value
  end
  return parts
end

describe('read-only is enforced by the server, per adapter', function()
  it('puts the documented switch on the wire for a read-only connection', function()
    for kind, want in pairs(MECHANISM) do
      local spec = vim.tbl_extend('force', want.spec, { read_only = true })
      local command = get(kind).command(spec, nil, 'records', CLIENTS)
      eq(
        h.has(flatten(command), want.switch),
        true,
        { fail_reason = ('%s must pass `%s` in %s'):format(kind, want.switch, want.where) }
      )
    end
  end)

  it('leaves a writable connection writable', function()
    for kind, want in pairs(MECHANISM) do
      local spec = vim.tbl_extend('force', want.spec, { read_only = false })
      local command = get(kind).command(spec, nil, 'records', CLIENTS)
      eq(
        h.has(flatten(command), want.switch),
        false,
        { fail_reason = ('%s must not force read-only on a writable connection'):format(kind) }
      )
    end
  end)

  --- Guards the pivot itself: an adapter that ignores `read_only` would be back to trusting the
  --- classifier, silently, and every unit test above would still pass for the other two.
  it('makes every registered adapter answer differently for a read-only connection', function()
    local kinds = require('dblens.adapters').kinds()
    eq(#kinds > 0, true)
    for _, kind in ipairs(kinds) do
      local base = MECHANISM[kind] and MECHANISM[kind].spec
      eq(
        base ~= nil,
        true,
        { fail_reason = ('adapter `%s` has no read-only mechanism'):format(kind) }
      )
      local adapter = get(kind)
      local writable = flatten(
        adapter.command(
          vim.tbl_extend('force', base, { read_only = false }),
          nil,
          'records',
          CLIENTS
        )
      )
      local locked = flatten(
        adapter.command(
          vim.tbl_extend('force', base, { read_only = true }),
          nil,
          'records',
          CLIENTS
        )
      )
      h.neq(
        locked,
        writable,
        { fail_reason = ('adapter `%s` builds the same command either way'):format(kind) }
      )
    end
  end)
end)

describe('the session opens a read-only connection read-only', function()
  it('spawns the client with the read-only switch', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod, { read_only = true })
      session:run('SELECT 1', {}, h.capture().sink)
      eq(#calls, 1)
      eq(h.has(calls[1].argv, '-readonly'), true)
    end)
  end)

  it('does not use it on a writable connection', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod)
      session:run('SELECT 1', {}, h.capture().sink)
      eq(#calls, 1)
      eq(h.has(calls[1].argv, '-readonly'), false)
    end)
  end)
end)

--- The opener each adapter must put in FRONT of a locked run. This is the guarantee: the session
--- switch above is session state a statement in the same run can turn off, an open read-only
--- transaction is not.
local WRAP = {
  postgres = 'BEGIN READ ONLY;',
  mysql = 'START TRANSACTION READ ONLY;',
}

describe('a locked run is sent inside a server-side read-only transaction', function()
  it('opens one per adapter, and leaves sqlite alone', function()
    for kind, opener in pairs(WRAP) do
      local script = get(kind).read_only_script('SELECT 1')
      eq(script:sub(1, #opener), opener, {
        fail_reason = ('%s must open a read-only transaction, got: %s'):format(kind, script),
      })
      eq(script:find('SELECT 1', 1, true) ~= nil, true)
    end
    -- sqlite's `-readonly` is the file open mode, so there is no session state to wrap.
    eq(get('sqlite').read_only_script('SELECT 1'), 'SELECT 1')
  end)

  --- PostgreSQL lets `SET TRANSACTION READ WRITE` escalate a read-only transaction until the
  --- transaction has taken a snapshot. Verified live: without the pin the INSERT lands.
  it('pins the postgres transaction with a snapshot before the caller runs', function()
    local script = get('postgres').read_only_script('SELECT 1')
    local pin = script:find('DECLARE', 1, true)
    local statement = script:find('SELECT 1', 1, true)
    eq(pin ~= nil and statement ~= nil and pin < statement, true, {
      fail_reason = 'the snapshot pin must come before the caller statement: ' .. script,
    })
  end)

  it('every registered adapter can open a locked run', function()
    for _, kind in ipairs(require('dblens.adapters').kinds()) do
      local script = get(kind).read_only_script('SELECT 1')
      eq(type(script) == 'string' and script:find('SELECT 1', 1, true) ~= nil, true, {
        fail_reason = ('adapter `%s` produced no usable read-only script'):format(kind),
      })
    end
  end)

  it('puts the wrap on the wire for a locked run, and nothing extra for a writable one', function()
    for kind, opener in pairs(WRAP) do
      local spec = vim.tbl_extend('force', MECHANISM[kind].spec, { read_only = true })
      h.with_fake_exec(function()
        return {}
      end, function(session_mod, calls)
        local session = h.fake_session(session_mod, spec)
        session:run('SELECT 1', {}, h.capture().sink)
        eq(#calls, 1)
        eq(calls[1].stdin, get(kind).read_only_script('SELECT 1'))
        eq(calls[1].stdin:sub(1, #opener), opener)

        local writable =
          h.fake_session(session_mod, vim.tbl_extend('force', spec, { read_only = false }))
        writable:run('SELECT 1', {}, h.capture().sink)
        eq(#calls, 2)
        eq(calls[2].stdin, 'SELECT 1', {
          fail_reason = ('%s wrapped a writable run, which would break the commit batch'):format(
            kind
          ),
        })
      end)
    end
  end)
end)

--- Statements that a read-only connection must not be able to apply. The first is the exploit
--- that defeated the classifier on sqlite and mysql; the rest are the plain writes it is meant
--- to stop. Each is sent WITHOUT classification, so what is being tested is the server.
local WRITES = {
  { name = 'nested block comment stacks a DROP', sql = 'SELECT 1 /* /* */ ; DROP TABLE victim' },
  { name = 'DROP TABLE', sql = 'DROP TABLE victim' },
  { name = 'DELETE', sql = 'DELETE FROM victim' },
  { name = 'UPDATE', sql = 'UPDATE victim SET a = 99' },
  {
    name = 'INSERT behind a CTE',
    sql = 'WITH x AS (SELECT 2 AS n) INSERT INTO victim SELECT n FROM x',
  },
  { name = 'CREATE TABLE', sql = 'CREATE TABLE sneaky(a int)' },
  { name = 'ALTER TABLE', sql = 'ALTER TABLE victim ADD COLUMN b int' },
}

describe('sqlite3, live: the server refuses the write, not the classifier', function()
  local sqlite = get('sqlite')
  local scratch = nil

  local function have_client()
    return vim.fn.executable(CLIENTS.sqlite) == 1
  end

  local function seed()
    local db = ('%s/victim-%d.db'):format(scratch, math.random(1, 2 ^ 30))
    local made = vim
      .system({
        CLIENTS.sqlite,
        '-batch',
        db,
        'CREATE TABLE victim(a int); INSERT INTO victim VALUES (1);',
      })
      :wait()
    assert(made.code == 0, 'readonly_spec: could not seed the scratch database: ' .. made.stderr)
    return db
  end

  --- Every byte of the database, plus the two facts a reader of a failure wants named.
  local function state_of(db)
    local file = assert(io.open(db, 'rb'), 'readonly_spec: scratch database vanished')
    local bytes = file:read('*a')
    file:close()
    local exists = vim
      .system({
        CLIENTS.sqlite,
        '-batch',
        db,
        "SELECT count(*) FROM sqlite_schema WHERE name = 'victim'",
      })
      :wait()
    local rows = vim.system({ CLIENTS.sqlite, '-batch', db, 'SELECT count(*) FROM victim' }):wait()
    return {
      bytes = bytes,
      victim = vim.trim(exists.stdout),
      rows = rows.code == 0 and vim.trim(rows.stdout) or 'gone',
    }
  end

  --- Run `statement` over the argv the adapter really builds, with no gate in front of it.
  local function send(db, read_only, statement)
    local command =
      sqlite.command({ kind = 'sqlite', path = db, read_only = read_only }, nil, 'records', CLIENTS)
    return vim.system(command.argv, { stdin = statement }):wait()
  end

  before_each(function()
    scratch = vim.fn.tempname()
    vim.fn.mkdir(scratch, 'p')
  end)

  after_each(function()
    if scratch then
      vim.fn.delete(scratch, 'rf')
    end
  end)

  it('applies every one of these writes on a WRITABLE connection', function()
    if not have_client() then
      MiniTest.add_note('sqlite3 is not installed; the live read-only proof did not run')
      return
    end
    for _, case in ipairs(WRITES) do
      local db = seed()
      local before = state_of(db)
      send(db, false, case.sql)
      local after = state_of(db)
      h.neq(after.bytes, before.bytes, {
        fail_reason = ('%s changed nothing even when allowed, so the read-only case proves nothing'):format(
          case.name
        ),
      })
    end
  end)

  it('has the SERVER refuse every one of them on a read-only connection', function()
    if not have_client() then
      MiniTest.add_note('sqlite3 is not installed; the live read-only proof did not run')
      return
    end
    for _, case in ipairs(WRITES) do
      local db = seed()
      local before = state_of(db)
      local result = send(db, true, case.sql)
      local after = state_of(db)
      eq(result.code ~= 0, true, {
        fail_reason = ('%s: the client exited 0, so the server did not refuse it'):format(
          case.name
        ),
      })
      eq(after.bytes, before.bytes, {
        fail_reason = ('%s: the database changed on a read-only connection'):format(case.name),
      })
      eq({ after.victim, after.rows }, { '1', '1' }, {
        fail_reason = ('%s: `victim` was altered on a read-only connection'):format(case.name),
      })
    end
  end)

  it('still lets ordinary reads through', function()
    if not have_client() then
      MiniTest.add_note('sqlite3 is not installed; the live read-only proof did not run')
      return
    end
    local db = seed()
    for _, statement in ipairs({
      'SELECT count(*) FROM victim',
      "SELECT REPLACE('abc', 'a', 'z')",
      'SELECT a FROM victim ORDER BY a',
    }) do
      local result = send(db, true, statement)
      eq(result.code, 0, {
        fail_reason = ('a read-only connection refused the read `%s`: %s'):format(
          statement,
          result.stderr
        ),
      })
    end
  end)

  --- The classifier is UX now, so it may not be the thing keeping these safe -- but it must not
  --- have stopped recognising them either.
  it('also classifies every one of them as a write', function()
    for _, case in ipairs(WRITES) do
      eq(sql.classify(case.sql, sql.dialects.sqlite).write, true, {
        fail_reason = ('%s should still prompt on a writable connection'):format(case.name),
      })
    end
  end)
end)

--- Payloads that turn the read-only switch off mid-run and then write. Every one of them LANDED
--- a write on a `read_only = true` connection before the transaction wrap; inside an open
--- read-only transaction the server refuses them, because a `SET` retargets only LATER
--- transactions and the switch of the running one can no longer be changed.
local FLIPS = {
  postgres = {
    {
      name = 'SET default_transaction_read_only = off',
      sql = 'SET default_transaction_read_only = off; INSERT INTO victim VALUES (99)',
    },
    {
      name = 'set_config() flip',
      sql = "SELECT set_config('default_transaction_read_only','off',false);"
        .. ' INSERT INTO victim VALUES (98)',
    },
    {
      name = 'SET TRANSACTION READ WRITE',
      sql = 'SET TRANSACTION READ WRITE; INSERT INTO victim VALUES (97)',
    },
    { name = 'plain INSERT', sql = 'INSERT INTO victim VALUES (96)' },
    { name = 'DROP TABLE', sql = 'DROP TABLE victim' },
  },
  mysql = {
    {
      name = 'SET SESSION TRANSACTION READ WRITE',
      sql = 'SET SESSION TRANSACTION READ WRITE; INSERT INTO victim VALUES (99)',
    },
    {
      name = 'the same flip hidden behind MySQL `--1`',
      sql = 'SELECT 1 --1; SET SESSION TRANSACTION READ WRITE; INSERT INTO victim VALUES (98)',
    },
    { name = 'plain INSERT', sql = 'INSERT INTO victim VALUES (97)' },
    { name = 'DROP TABLE', sql = 'DROP TABLE victim' },
  },
}

--- A live server, described entirely by environment so the suite stays green without one.
---@return { spec: table, secret: string?, clients: table }?
local function live_target(kind)
  local prefix = 'DBLENS_TEST_' .. kind:upper()
  local port = tonumber(vim.env[prefix .. '_PORT'] or '')
  if not port then
    return nil
  end
  local clients = vim.tbl_extend('force', CLIENTS, {})
  clients[kind] = vim.env[prefix .. '_CLIENT'] or CLIENTS[kind]
  return {
    spec = {
      name = 'live',
      kind = kind,
      host = vim.env[prefix .. '_HOST'] or '127.0.0.1',
      port = port,
      user = vim.env[prefix .. '_USER'],
      database = vim.env[prefix .. '_DB'] or 'app',
    },
    secret = vim.env[prefix .. '_PASSWORD'],
    clients = clients,
  }
end

--- A real `dblens.session.Session` in the requested mode. The spec is untouched: `set_locked`
--- is the runtime toggle a user reaches through `:DbLensWrite` / `:DbLensLock`.
local function live_session(target, locked)
  local session, err =
    require('dblens.session').new(vim.deepcopy(target.spec), require('dblens.config').setup({}))
  assert(session, tostring(err))
  session.secret = target.secret
  assert(session:set_locked(locked))
  return session
end

--- Send `statement` the way `Session:run` would: the argv the session's mode picks, and the
--- stdin it composes. Synchronous, so the assertion can go and read the server afterwards.
local function send(target, locked, statement)
  local session = live_session(target, locked)
  local command =
    session.adapter.command(session:client_spec(), session.secret, 'records', target.clients)
  return vim
    .system(command.argv, { env = command.env, stdin = session:stdin_for(statement) })
    :wait(60000)
end

--- Rows in `victim`, read over a writable connection so the count is the server's own.
---@return string
local function victim_rows(target, adapter)
  local out = send(target, false, 'SELECT count(*) AS n FROM victim')
  if out.code ~= 0 then
    return 'gone'
  end
  local first = adapter.decode(out.stdout, {}).rows[1]
  return first and tostring(first[1]) or 'none'
end

local function seed(target)
  local out = send(
    target,
    false,
    'DROP TABLE IF EXISTS victim; CREATE TABLE victim(a int); INSERT INTO victim VALUES (1);'
  )
  assert(out.code == 0, 'readonly_spec: could not seed victim: ' .. tostring(out.stderr))
end

--- The live proof, identical in shape for both servers: every flip must change the table on a
--- writable connection (or the read-only assertion proves nothing) and must leave it untouched
--- on a locked one.
local function describe_live(kind)
  describe(('%s, live: the read-only transaction refuses the in-band flip'):format(kind), function()
    local adapter = get(kind)
    local target = nil

    local function skip()
      if target then
        return false
      end
      MiniTest.add_note(
        ('no %s server (set DBLENS_TEST_%s_PORT); the live flip proof did not run'):format(
          kind,
          kind:upper()
        )
      )
      return true
    end

    before_each(function()
      target = live_target(kind)
    end)

    it('applies every flip on a WRITABLE connection', function()
      if skip() then
        return
      end
      for _, case in ipairs(FLIPS[kind]) do
        seed(target)
        local before = victim_rows(target, adapter)
        send(target, false, case.sql)
        h.neq(victim_rows(target, adapter), before, {
          fail_reason = ('%s changed nothing even when allowed, so the locked case proves nothing'):format(
            case.name
          ),
        })
      end
    end)

    it('has the SERVER refuse every flip on a locked connection', function()
      if skip() then
        return
      end
      for _, case in ipairs(FLIPS[kind]) do
        seed(target)
        local before = victim_rows(target, adapter)
        local result = send(target, true, case.sql)
        eq(result.code ~= 0, true, {
          fail_reason = ('%s: the client exited 0, so the server did not refuse it'):format(
            case.name
          ),
        })
        eq(victim_rows(target, adapter), before, {
          fail_reason = ('%s: the table changed on a locked connection'):format(case.name),
        })
      end
    end)

    it('still lets ordinary reads through the wrap', function()
      if skip() then
        return
      end
      seed(target)
      for _, statement in ipairs({
        'SELECT count(*) AS n FROM victim',
        'SELECT a FROM victim ORDER BY a',
      }) do
        local result = send(target, true, statement)
        eq(result.code, 0, {
          fail_reason = ('a locked connection refused the read `%s`: %s'):format(
            statement,
            result.stderr
          ),
        })
        eq(#adapter.decode(result.stdout, {}).rows > 0, true, {
          fail_reason = ('the wrap swallowed the rows of `%s`'):format(statement),
        })
      end
    end)

    --- The toggle is the only way to write, and it really does change what the server does.
    it('writes only after the toggle, and refuses again after locking back', function()
      if skip() then
        return
      end
      seed(target)
      local session = live_session(target, true)
      local write = 'INSERT INTO victim VALUES (4242)'

      local locked = send(target, session:is_read_only(), write)
      eq({ session:mode(), locked.code ~= 0 }, { 'LOCKED', true })
      local before = victim_rows(target, adapter)

      assert(session:set_locked(false))
      local unlocked = send(target, session:is_read_only(), write)
      eq({ session:mode(), unlocked.code }, { 'EDIT', 0 })
      h.neq(
        victim_rows(target, adapter),
        before,
        { fail_reason = 'the toggle did not enable a write' }
      )

      assert(session:set_locked(true))
      local relocked = send(target, session:is_read_only(), write)
      local after = victim_rows(target, adapter)
      eq({ session:mode(), relocked.code ~= 0 }, { 'LOCKED', true })
      eq(victim_rows(target, adapter), after, { fail_reason = 'locking back did not re-engage' })
    end)
  end)
end

describe_live('postgres')
describe_live('mysql')

describe('the MySQL `--` rule', function()
  local PAYLOAD = 'SELECT 1 --1; SET SESSION TRANSACTION READ WRITE; INSERT INTO victim VALUES (1)'

  --- MySQL needs whitespace after the second dash, so `--1` is arithmetic and the rest of the
  --- line is live SQL. Reading it as a comment hid a stacked write from the classifier, and a
  --- write landed on a `read_only = true` MySQL connection.
  it('sees the stacked write that hides behind `--1` on mysql', function()
    eq(#sql.split(PAYLOAD, sql.dialects.mysql), 3, {
      fail_reason = 'mysql splits `--1` into three statements, so the lexer must too',
    })
    eq(sql.classify(PAYLOAD, sql.dialects.mysql).write, true)
    eq(sql.classify('SELECT 1 --1; DROP TABLE shrine', sql.dialects.mysql).destructive, true)
  end)

  it('still treats `--1` as a comment where the server does', function()
    for _, dialect in ipairs({ sql.dialects.sqlite, sql.dialects.postgres }) do
      eq(#sql.split(PAYLOAD, dialect), 1)
      eq(sql.classify(PAYLOAD, dialect).write, false)
    end
  end)

  it('still treats `-- text` as a comment on every dialect', function()
    for name, dialect in pairs(sql.dialects) do
      eq(sql.classify('SELECT 1 -- ; DROP TABLE t', dialect).write, false, {
        fail_reason = ('`-- ` stopped being a comment on %s'):format(name),
      })
      eq(sql.classify('-- just a comment', dialect).verb, '')
    end
  end)

  --- BLOCKER-2 of the final review: the same payload dropped a table on a WRITABLE connection
  --- with no prompt at all.
  it('fires the confirm gate for the payload on a writable mysql connection', function()
    local session = h.fake_session(
      require('dblens.session'),
      { kind = 'mysql', database = 'app', read_only = false }
    )
    eq(session:gate('SELECT 1 --1; DROP TABLE shrine'), 'this change was not confirmed')
    eq(session:gate('SELECT 1 --1; DROP TABLE shrine', { confirmed = true }), nil)
  end)
end)

--- What the server still cannot stop on postgres/mysql: a statement that ENDS or REPLACES
--- dblens's read-only transaction and writes in a fresh one. Verified live that each of these
--- lands when sent anyway, so the gate is what refuses them -- which it does because none of
--- them is a single provable read. These assertions are that layer's alarm.
local ESCAPES = {
  postgres = {
    'ROLLBACK; SET default_transaction_read_only = off; BEGIN; INSERT INTO victim VALUES (7)',
    'COMMIT; SET default_transaction_read_only = off; INSERT INTO victim VALUES (7)',
  },
  mysql = {
    'START TRANSACTION READ WRITE; INSERT INTO victim VALUES (7)',
    'COMMIT; SET SESSION TRANSACTION READ WRITE; INSERT INTO victim VALUES (7)',
  },
}

describe('the statements that can still leave the read-only transaction', function()
  it('classifies every one of them as a write, on its own dialect and permissively', function()
    for kind, payloads in pairs(ESCAPES) do
      for _, payload in ipairs(payloads) do
        eq(sql.classify(payload, sql.dialects[kind]).write, true, {
          fail_reason = ('%s: `%s` must never classify as a read'):format(kind, payload),
        })
        eq(sql.classify(payload).write, true, {
          fail_reason = ('permissive: `%s` must never classify as a read'):format(payload),
        })
      end
    end
  end)

  it('refuses them on a locked connection before a client is spawned', function()
    for kind, payloads in pairs(ESCAPES) do
      local session = h.fake_session(
        require('dblens.session'),
        vim.tbl_extend('force', MECHANISM[kind].spec, { read_only = true })
      )
      for _, payload in ipairs(payloads) do
        eq(session:gate(payload), 'connection `test` is read-only', {
          fail_reason = ('%s: `%s` reached the client'):format(kind, payload),
        })
      end
    end
  end)
end)

describe('a connection is LOCKED unless it opted out', function()
  it('locks a connection that says nothing about read_only', function()
    local options = require('dblens.config').setup({})
    eq(options.safety.read_only_default, true)
    local session = assert(
      require('dblens.session').new({ name = 'x', kind = 'sqlite', path = '/tmp/x.db' }, options)
    )
    eq({ session:is_read_only(), session:mode() }, { true, 'LOCKED' })
  end)

  it('opens only on an explicit `read_only = false`', function()
    local options = require('dblens.config').setup({})
    local session = assert(
      require('dblens.session').new(
        { name = 'x', kind = 'sqlite', path = '/tmp/x.db', read_only = false },
        options
      )
    )
    eq({ session:is_read_only(), session:mode() }, { false, 'EDIT' })
  end)

  --- The connections file is hand-editable JSON, and a truthy non-boolean used to read as
  --- "read-only" in the picker while enforcement compared `== true` and allowed every write.
  it('resolves a non-boolean read_only to LOCKED', function()
    local options = require('dblens.config').setup({
      connections = { { name = 'odd', kind = 'sqlite', path = '/tmp/x.db', read_only = 1 } },
      connections_file = vim.fn.tempname(),
    })
    local specs, problems = require('dblens.connections').load(options)
    eq({ #specs, #problems }, { 1, 0 })
    eq(specs[1].read_only, true)
  end)

  it('toggles the mode, and the toggle decides the argv the next run spawns with', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod, { read_only = true })
      session:run('SELECT 1', {}, h.capture().sink)
      eq({ session:mode(), h.has(calls[1].argv, '-readonly') }, { 'LOCKED', true })

      eq({ session:set_locked(false) }, { true })
      session:run('SELECT 1', {}, h.capture().sink)
      eq({ session:mode(), h.has(calls[2].argv, '-readonly') }, { 'EDIT', false })

      eq({ session:set_locked(true) }, { true })
      session:run('SELECT 1', {}, h.capture().sink)
      eq({ session:mode(), h.has(calls[3].argv, '-readonly') }, { 'LOCKED', true })
      eq(calls[3].stdin, 'SELECT 1', { fail_reason = 'sqlite needs no wrap' })
    end)
  end)

  it('refuses a write while locked and allows the confirmed one after the toggle', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod, { read_only = true })
      local box = h.capture()
      session:execute_write({ sql = 'DELETE FROM t', summary = 'd', destructive = true }, box.sink)
      eq({ box[1], box[2] }, { nil, 'connection `test` is read-only' })
      eq(#calls, 0)

      assert(session:set_locked(false))
      local unconfirmed = h.capture()
      session:execute_write(
        { sql = 'DELETE FROM t', summary = 'd', destructive = true },
        unconfirmed.sink
      )
      eq({ unconfirmed[1], unconfirmed[2] }, { nil, 'this change was not confirmed' }, {
        fail_reason = 'the toggle must not also clear the destructive-change confirmation',
      })
      eq(#calls, 0)

      local confirmed = h.capture()
      session:execute_write({
        sql = 'DELETE FROM t',
        summary = 'd',
        destructive = true,
        confirmed = true,
      }, confirmed.sink)
      eq(#calls, 1)
      eq(confirmed[2], nil)
    end)
  end)
end)
