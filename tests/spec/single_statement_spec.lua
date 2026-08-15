--- A LOCKED connection runs ONE statement, and refuses anything it cannot PROVE is one.
---
--- Four adversarial reviews found the same shape of bug four times: dblens's lexer and the
--- server's disagree about where a statement ends, so a stacked write hides in the gap. The last
--- one was a bare `\r`, which psql reads as the end of a `--` comment and this lexer did not.
---
--- Adding `\r` to the lexer would only move the gap. What closes the class is structural: the
--- read-only transaction makes a SINGLE statement unescapable on every engine, so a locked
--- connection refuses every input that is not provably single. There is then nothing left for the
--- lexer to be wrong about.
---
--- The live cases need a server (`DBLENS_TEST_POSTGRES_PORT` / `DBLENS_TEST_MYSQL_PORT`); the
--- sqlite ones only need `sqlite3`. Without either they add a note and skip.
local h = require('helpers')
local sql = require('dblens.sql')
local session_mod = require('dblens.session')

local eq = h.eq

--- Every framing byte or sequence a client could read as a line break where this lexer sees
--- ordinary text. `\r` is the one that landed a DROP; the rest are the same class, refused before
--- anyone has to find out which engine honours them.
local FRAMINGS = {
  { name = 'CR', sep = '\13' },
  { name = 'VT', sep = '\11' },
  { name = 'FF', sep = '\12' },
  { name = 'NUL', sep = '\0' },
  { name = 'FS', sep = '\28' },
  { name = 'GS', sep = '\29' },
  { name = 'RS', sep = '\30' },
  { name = 'US', sep = '\31' },
  { name = 'U+2028', sep = '\226\128\168' },
  { name = 'U+2029', sep = '\226\128\169' },
  { name = 'U+0085', sep = '\194\133' },
}

-- ---------------------------------------------------------------------------
-- the rule itself

describe('proving an input is exactly one statement', function()
  it('accepts the shapes a read-only browser actually sends', function()
    for _, statement in ipairs({
      'SELECT 1',
      'SELECT 1;',
      '  SELECT 1 ;  ',
      '\nSELECT 1\n;\n',
      'SELECT a,\n       b\nFROM t\nWHERE a = 1',
      'SELECT 1 -- a trailing note',
      'SELECT 1 -- a note ending in ;',
      "SELECT * FROM t WHERE name = 'a b'",
      'SELECT count(*) AS n FROM "my table"',
      'SELECT\t1',
    }) do
      eq(sql.single_statement_problem(statement), nil, {
        fail_reason = ('a locked connection refused the single statement `%s`'):format(statement),
      })
    end
  end)

  --- Built by concatenation, not `format`: `string.format('%s', '\0')` truncates at the NUL and
  --- would quietly test a different payload.
  it('refuses every framing character, wherever it sits', function()
    for _, framing in ipairs(FRAMINGS) do
      for index, shape in ipairs({
        { 'SELECT 1 -- x', 'DROP TABLE t' },
        { 'SELECT', '1' },
        { '', 'SELECT 1' },
        { 'SELECT 1', '' },
        { "SELECT 'a", "b'" },
      }) do
        local problem = sql.single_statement_problem(shape[1] .. framing.sep .. shape[2])
        eq(type(problem) == 'string', true, {
          fail_reason = ('%s went unnoticed in shape %d'):format(framing.name, index),
        })
      end
    end
  end)

  it('refuses a `;` anywhere but the very end', function()
    for _, statement in ipairs({
      'SELECT 1; SELECT 2',
      'SELECT 1;;',
      "SELECT ';'",
      '; SELECT 1',
      'SELECT 1;DROP TABLE t',
    }) do
      eq(type(sql.single_statement_problem(statement)) == 'string', true, {
        fail_reason = ('`%s` passed as a single statement'):format(statement),
      })
    end
  end)

  it('names what it found, so the message can be acted on', function()
    eq(sql.single_statement_problem('SELECT 1\13'):find('0x0D', 1, true) ~= nil, true)
    eq(sql.single_statement_problem('SELECT 1\226\128\168'):find('U+2028', 1, true) ~= nil, true)
    eq(sql.single_statement_problem('SELECT 1; SELECT 2'):find('`;`', 1, true) ~= nil, true)
  end)
end)

--- Ending a comment EARLY is the fail-safe direction: it puts hidden text back in the code
--- stream. The rule above already refuses these inputs, so this is the second layer.
describe('comment scanning treats every framing character as end-of-line', function()
  it('exposes a stacked statement hidden behind a comment', function()
    for _, framing in ipairs(FRAMINGS) do
      local payload = 'SELECT 1 -- x' .. framing.sep .. '; DROP TABLE victim'
      eq(#sql.split(payload, sql.dialects.postgres), 2, {
        fail_reason = ('%s still hid the stacked DROP from the splitter'):format(framing.name),
      })
      eq(sql.classify(payload, sql.dialects.postgres).write, true, {
        fail_reason = ('%s still classified a hidden DROP as a read'):format(framing.name),
      })
    end
  end)

  it('leaves an ordinary comment alone', function()
    eq(#sql.split('SELECT 1 -- ; DROP TABLE t', sql.dialects.postgres), 1)
    eq(sql.classify('SELECT 1 -- ; DROP TABLE t', sql.dialects.postgres).write, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- the gate

--- Payloads a locked connection must refuse. Each hides a stacked write behind a `--` comment
--- that the framing character ends for the server.
local function refusable_payloads()
  local out = {}
  for _, framing in ipairs(FRAMINGS) do
    out[#out + 1] = {
      name = framing.name,
      sql = 'SELECT 1 -- x' .. framing.sep .. ';ROLLBACK;' .. framing.sep .. 'DROP TABLE victim',
    }
  end
  out[#out + 1] = { name = 'plain `;` pair', sql = 'SELECT 1; DROP TABLE victim' }
  out[#out + 1] = { name = 'comment, newline, write', sql = 'SELECT 1 -- x\n; DROP TABLE victim' }
  return out
end

describe('a locked connection refuses what it cannot prove is one statement', function()
  it('refuses every framing without contacting a server', function()
    h.with_fake_exec(function()
      return {}
    end, function(mod, calls)
      local session = h.fake_session(mod, { read_only = true })
      for _, case in ipairs(refusable_payloads()) do
        local box = h.capture()
        session:run(case.sql, {}, box.sink)
        eq(#calls, 0, { fail_reason = ('%s reached a client'):format(case.name) })
        eq(box[1], nil, { fail_reason = ('%s returned a result'):format(case.name) })
        eq(type(box[2]) == 'string', true, {
          fail_reason = ('%s was not refused'):format(case.name),
        })
      end
    end)
  end)

  --- A refusal a user cannot act on is a bug report waiting to happen: it must name the mode and
  --- the way out, not read like a client error.
  it('says it is the lock, and how to lift it', function()
    local session = h.fake_session(require('dblens.session'), { read_only = true })
    local refusal = session:gate('SELECT 1; SELECT 2')
    eq(type(refusal) == 'string', true)
    for _, needle in ipairs({ '`test`', 'LOCKED', 'one statement at a time', ':DbLensWrite' }) do
      eq(refusal:find(needle, 1, true) ~= nil, true, {
        fail_reason = ('the refusal never mentions %s: %s'):format(needle, refusal),
      })
    end
  end)

  it('still runs a single statement, with or without a trailing `;`', function()
    h.with_fake_exec(function()
      return {}
    end, function(mod, calls)
      local session = h.fake_session(mod, { read_only = true })
      for _, statement in ipairs({ 'SELECT 1', 'SELECT 1;', 'SELECT a\nFROM t\nWHERE a = 1' }) do
        local box = h.capture()
        session:run(statement, {}, box.sink)
        eq(box[2], nil, {
          fail_reason = ('a locked connection refused the read `%s`: %s'):format(
            statement,
            tostring(box[2])
          ),
        })
      end
      eq(#calls, 3)
    end)
  end)

  --- EDIT mode is the sanctioned multi-statement path, and this rule must not reach into it: the
  --- confirmation gate is what stands in front of a write there.
  it('leaves EDIT mode alone, where the confirmation gate takes over', function()
    local session = h.fake_session(require('dblens.session'), { read_only = false })
    eq(session:gate('SELECT 1; DROP TABLE victim'), 'this change was not confirmed')
    eq(session:gate('SELECT 1; DROP TABLE victim', { confirmed = true }), nil)
    eq(session:gate('SELECT 1 -- x\13; SELECT 2', { confirmed = true }), nil)
  end)

  --- The gate is what holds this invariant, so a future caller that skips it must fail loudly
  --- rather than put an unprovable script on the wire.
  it('refuses to compose stdin for a locked run of more than one statement', function()
    local session = h.fake_session(require('dblens.session'), { read_only = true })
    h.expect_error(function()
      session:stdin_for('SELECT 1; DROP TABLE victim')
    end, 'one statement')
    eq(session:stdin_for('SELECT 1'), 'SELECT 1')
  end)
end)

-- ---------------------------------------------------------------------------
-- live

local function make_session(target, locked)
  local session = assert(
    session_mod.new(
      vim.deepcopy(target.spec),
      require('dblens.config').setup({ clients = target.clients })
    )
  )
  session.secret = target.secret
  assert(session:set_locked(locked))
  return session
end

--- Straight to the client on a WRITABLE connection, with no gate: seeding, fingerprints, and the
--- control that proves a payload is not a no-op.
local function writable(target, statement)
  local session = make_session(target, false)
  local command =
    session.adapter.command(session:client_spec(), session.secret, 'raw', target.clients)
  return vim
    .system(command.argv, { env = command.env, stdin = statement, text = false })
    :wait(60000)
end

--- `count(*)` and `sum(a)` of `victim`, read over a WRITABLE connection so the answer is the
--- server's own. 'GONE' when the table is not there any more.
local function fingerprint(target)
  local out = writable(target, 'SELECT count(*), sum(a) FROM victim')
  if out.code ~= 0 then
    return 'GONE'
  end
  return (vim.trim(out.stdout):gsub('%s+', ' '))
end

local function seed(target)
  local out = writable(
    target,
    'DROP TABLE IF EXISTS victim; CREATE TABLE victim(a int); INSERT INTO victim VALUES (1);'
  )
  assert(out.code == 0, 'single_statement_spec: could not seed victim: ' .. tostring(out.stderr))
end

--- Run `payload` through the REAL `Session:run` on a locked session, synchronously.
---@return string? refusal
local function locked_run(target, payload)
  local session = make_session(target, true)
  local done, err = false, nil
  session:run(payload, {}, function(_, run_err)
    err, done = run_err, true
  end)
  local finished = vim.wait(60000, function()
    return done
  end, 20)
  assert(finished, 'single_statement_spec: the locked run never called back')
  return err
end

--- The statements that leave the read-only transaction and write, per engine.
local function escape_tail(kind, sep, value)
  local parts = {
    postgres = {
      'ROLLBACK;',
      'SET default_transaction_read_only=off;',
      'BEGIN;',
      ('INSERT INTO victim VALUES (%d);'):format(value),
      'COMMIT;',
    },
    mysql = {
      'COMMIT;',
      'SET SESSION TRANSACTION READ WRITE;',
      'START TRANSACTION READ WRITE;',
      ('INSERT INTO victim VALUES (%d);'):format(value),
      'COMMIT;',
    },
    sqlite = { ('INSERT INTO victim VALUES (%d);'):format(value) },
  }
  return table.concat(assert(parts[kind], 'single_statement_spec: no escape for ' .. kind), sep)
end

--- Every framing of the hidden stacked write, plus the two plainly-separated forms.
local function live_payloads(kind)
  local out = {}
  for _, framing in ipairs(FRAMINGS) do
    out[#out + 1] = {
      name = ('hidden behind `-- x` + %s'):format(framing.name),
      sql = 'SELECT 1 -- x'
        .. framing.sep
        .. ';'
        .. escape_tail(kind, framing.sep, 301)
        .. framing.sep
        .. '--',
    }
  end
  out[#out + 1] = {
    name = 'CR-hidden DROP TABLE (the reported exploit)',
    sql = 'SELECT 1 -- x\13;ROLLBACK;\13SET default_transaction_read_only=off;\13'
      .. 'DROP TABLE victim;\13--',
  }
  out[#out + 1] = {
    name = 'plain `;`-separated pair',
    sql = 'SELECT 1; ' .. escape_tail(kind, ' ', 302),
  }
  out[#out + 1] = {
    name = 'comment, newline, then the write',
    sql = 'SELECT 1 -- x\n;' .. escape_tail(kind, '\n', 303) .. '\n--',
  }
  return out
end

--- Payloads THIS engine really does honour, so the refusals above are refusals and not no-ops.
--- Only postgres ends a `--` comment at a bare `\r`; the other framings change nothing on these
--- versions, which is exactly why refusing them all is the fix rather than matching one lexer.
local CONTROLS = {
  postgres = { 'CR-hidden DROP TABLE (the reported exploit)', 'plain `;`-separated pair' },
  mysql = { 'plain `;`-separated pair' },
  sqlite = { 'plain `;`-separated pair' },
}

local function describe_live(kind, resolve)
  describe(('%s, live: a LOCKED connection refuses every framing'):format(kind), function()
    local target = nil

    local function skip()
      if target then
        return false
      end
      MiniTest.add_note(('no live %s target; the framing proof did not run'):format(kind))
      return true
    end

    before_each(function()
      target = resolve()
    end)

    it('refuses every framing, and the table is untouched', function()
      if skip() then
        return
      end
      for _, case in ipairs(live_payloads(kind)) do
        seed(target)
        local before = fingerprint(target)
        local refusal = locked_run(target, case.sql)
        eq(type(refusal) == 'string', true, {
          fail_reason = ('%s: %s was not refused'):format(kind, case.name),
        })
        eq(fingerprint(target), before, {
          fail_reason = ('%s: %s changed the table on a LOCKED connection'):format(kind, case.name),
        })
      end
    end)

    --- Without this the refusals above could all be vacuous.
    it('applies the payloads this engine honours on a WRITABLE connection', function()
      if skip() then
        return
      end
      local wanted, by_name = CONTROLS[kind], {}
      for _, case in ipairs(live_payloads(kind)) do
        by_name[case.name] = case.sql
      end
      for _, name in ipairs(wanted) do
        seed(target)
        local before = fingerprint(target)
        writable(target, assert(by_name[name], 'single_statement_spec: no such payload: ' .. name))
        h.neq(fingerprint(target), before, {
          fail_reason = ('%s: `%s` changed nothing even when allowed'):format(kind, name),
        })
      end
    end)

    it('still runs an ordinary read, with and without a trailing `;`', function()
      if skip() then
        return
      end
      seed(target)
      for _, statement in ipairs({
        'SELECT count(*) FROM victim',
        'SELECT count(*) FROM victim;',
        'SELECT a\nFROM victim\nORDER BY a',
      }) do
        eq(locked_run(target, statement), nil, {
          fail_reason = ('%s: a locked connection refused the read `%s`'):format(kind, statement),
        })
      end
    end)

    --- EDIT mode is where more than one statement belongs. The framing rule does not apply there;
    --- the destructive-change confirmation does, and a stacked script inherits the danger of its
    --- most dangerous part. A purely additive script runs unprompted, per `confirm_write = false`.
    it('runs a confirmed multi-statement write once the connection is unlocked', function()
      if skip() then
        return
      end
      seed(target)
      local before = fingerprint(target)
      local session = make_session(target, false)

      local unconfirmed = h.capture()
      session:run('DELETE FROM victim; INSERT INTO victim VALUES (13)', {}, unconfirmed.sink)
      eq(unconfirmed[2], 'this change was not confirmed')
      eq(fingerprint(target), before, { fail_reason = 'an unconfirmed write landed in EDIT mode' })

      local done = false
      session:run(
        'INSERT INTO victim VALUES (11); INSERT INTO victim VALUES (12)',
        { approval = { confirmed = true } },
        function()
          done = true
        end
      )
      assert(
        vim.wait(60000, function()
          return done
        end, 20),
        'single_statement_spec: the EDIT-mode write never called back'
      )
      h.neq(fingerprint(target), before, {
        fail_reason = ('%s: a confirmed multi-statement write did not apply in EDIT mode'):format(
          kind
        ),
      })
    end)
  end)
end

describe_live('postgres', function()
  return h.live_target('postgres')
end)

describe_live('mysql', function()
  return h.live_target('mysql')
end)

local sqlite_scratch = nil

describe_live('sqlite', function()
  if vim.fn.executable('sqlite3') ~= 1 then
    return nil
  end
  sqlite_scratch = sqlite_scratch or vim.fn.tempname()
  vim.fn.mkdir(sqlite_scratch, 'p')
  return {
    spec = { name = 'live', kind = 'sqlite', path = sqlite_scratch .. '/victim.db', create = true },
    secret = nil,
    clients = h.CLIENTS,
  }
end)
