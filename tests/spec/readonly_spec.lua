--- Read-only is a SERVER guarantee, and this spec proves it the only way that means anything:
--- by sending a write to a real database over a real read-only connection and observing that
--- nothing changed.
---
--- Three adversarial reviews defeated the Lua classifier — nested block comments, MySQL
--- executable comments, backslash escaping under NO_BACKSLASH_ESCAPES, client meta-commands —
--- because dblens's lexer and the server's parse differently and every divergence is a bypass.
--- So the cases below DELIBERATELY skip `Session:gate`: a test that asks the classifier first
--- proves nothing about what protects a user from the divergence nobody has found yet.
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
