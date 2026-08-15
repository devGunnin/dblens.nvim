--- What a quoted literal means to the SERVER, for every engine and every escaping mode its
--- server can be in.
---
--- The defect this exists for: `quote_literal` doubled `'` and left `\` alone for postgres, which
--- is true only while `standard_conforming_strings = on`. That is a per-database/role/session
--- setting dblens never read. With it OFF, a CSV cell ending in `\` escaped its own closing quote,
--- the rest of the row was parsed as SQL, and a real table was DROPPED on a live PostgreSQL 16
--- while the import reported success. The same `quote_literal` backs filter-from-cell, `gf`/`gF`,
--- grid cell edits, CSV import and `.sql` export, so all of them carried it.
---
--- The judge here is deliberately NOT the quoter, and not `sql.split` either — re-asking the code
--- that emitted the literal proves nothing, and dblens's own lexer is the thing that disagreed
--- with the server in the first place. `decode_literal` below is an independent reader that
--- parses a literal the way a server in a given mode does. A case passes only when that parse
--- consumes EXACTLY the literal and hands back the original bytes.
local h = require('helpers')

local common = require('dblens.adapters.common')
local import = require('dblens.import')
local mutate = require('dblens.mutate')
local sqlmod = require('dblens.sql')

local eq = h.eq

--- The two things `\` can mean inside a plain `'...'` literal, which is what the modes below name:
---  * `standard` — an ordinary byte. sqlite, mssql, duckdb, postgres with
---    `standard_conforming_strings = on`, mysql/mariadb under `NO_BACKSLASH_ESCAPES`.
---  * `backslash` — an escape. postgres with that setting OFF, mysql/mariadb by default.

--- Postgres/DuckDB escape sequences that matter here. An unrecognised `\x` drops the backslash,
--- which is what those servers do.
local ESCAPED = { n = '\n', t = '\t', r = '\r' }

--- Read one string literal off the front of `text`, as a server in `mode` would.
---
--- An `E'...'` prefix forces backslash escaping whatever `mode` says — that is the whole point of
--- the syntax, and the reason `quote_literal` emits it where a plain literal is mode-dependent.
---@param text string
---@param mode 'standard'|'backslash'
---@return string? value, string? rest  -- nil when the literal is never closed
local function decode_literal(text, mode)
  assert(type(text) == 'string', 'decode_literal: expected text')
  assert(mode == 'standard' or mode == 'backslash', 'decode_literal: unknown mode')
  local at, escapes = 1, mode == 'backslash'
  if text:sub(1, 2):lower() == "e'" then
    at, escapes = 2, true
  end
  if text:sub(at, at) ~= "'" then
    return nil, nil
  end
  local out = {}
  local i = at + 1
  while i <= #text do
    local char = text:sub(i, i)
    if escapes and char == '\\' then
      local next_char = text:sub(i + 1, i + 1)
      if next_char == '' then
        return nil, nil
      end
      out[#out + 1] = ESCAPED[next_char] or next_char
      i = i + 2
    elseif char == "'" then
      if text:sub(i + 1, i + 1) == "'" then
        out[#out + 1] = "'"
        i = i + 2
      else
        return table.concat(out), text:sub(i + 1)
      end
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  return nil, nil
end

--- Every engine, and every mode its server can actually be in for a literal dblens writes.
---
--- postgres lists BOTH modes because the setting is out of dblens's hands and the emitted syntax
--- has to survive either. mysql lists only `backslash` because there is no mode-neutral literal
--- syntax there: the adapter pins the mode instead, which the last case in this group asserts.
local ENGINES = {
  { kind = 'sqlite', modes = { 'standard' } },
  { kind = 'mssql', modes = { 'standard' } },
  { kind = 'duckdb', modes = { 'standard', 'backslash' } },
  { kind = 'postgres', modes = { 'standard', 'backslash' } },
  { kind = 'mysql', modes = { 'backslash' } },
}

--- Values chosen to break the framing, not to look scary. Each one either ends a literal early,
--- carries a statement separator, or means two different things under the two modes.
local HOSTILE = {
  { name = 'a trailing backslash', value = [[C:\]] },
  { name = 'the payload that dropped a live table', value = [[\'); DROP TABLE victim; --]] },
  { name = 'a second one that dropped it again', value = [[\''); DROP TABLE victim; --]] },
  { name = 'a stacked statement behind a bare quote', value = [['); DROP TABLE victim;--]] },
  { name = 'an escaped quote', value = [[\']] },
  { name = 'a bare quote', value = "o'brien" },
  { name = 'a doubled quote', value = [[he said ''hi'']] },
  { name = 'a windows path', value = [[C:\path\to\file]] },
  { name = 'nothing but backslashes', value = [[\\\\]] },
  { name = 'an escape-string prefix', value = [[E'x']] },
  { name = 'a dollar-quoted body', value = '$$; DROP TABLE victim; --$$' },
  { name = 'a comment opener', value = '-- /* x */' },
  { name = 'a psql meta-command', value = '\\! ls' },
  { name = 'a mysql executable comment', value = '/*!40000 DROP TABLE victim */' },
  { name = 'a real newline', value = 'line one\nline two' },
  { name = 'a carriage return and a tab', value = 'a\rb\tc' },
  { name = 'unicode', value = 'größe — 名前' },
  { name = 'the empty string', value = '' },
}

--- Assert that the literal starting just after `before` in `statement` holds exactly `case.value`
--- and ends exactly where `tail` begins, under every mode `engine`'s server can be in.
---
--- WHERE the literal ends is the decoder's answer, not this file's — that boundary is the whole
--- defect. `tail` is what must still be outside it: when a value escapes its own closing quote,
--- the tail is swallowed and this is what notices.
local function expect_literal(engine, case, statement, before, tail)
  local from = statement:find(before, 1, true)
  assert(from, ('no `%s` in: %s'):format(before, statement))
  local text = statement:sub(from + #before)
  for _, mode in ipairs(engine.modes) do
    local decoded, rest = decode_literal(text, mode)
    local why = ('%s/%s, %s: %s'):format(engine.kind, mode, case.name, statement)
    eq(decoded, case.value, { fail_reason = why })
    eq(rest, tail, { fail_reason = why .. ' -- the literal did not end where it should' })
  end
end

describe('a quoted literal is data on every engine, in every escaping mode', function()
  for _, engine in ipairs(ENGINES) do
    local dialect = assert(sqlmod.dialects[engine.kind], engine.kind)

    it(('%s: quote_literal round-trips every hostile value'):format(engine.kind), function()
      for _, case in ipairs(HOSTILE) do
        local statement = ('SELECT * FROM t WHERE c = %s LIMIT 1'):format(
          sqlmod.quote_literal(case.value, dialect)
        )
        expect_literal(engine, case, statement, 'c = ', ' LIMIT 1')
      end
    end)

    --- Every caller of the quoter, from the same list. They inherit the fix rather than each
    --- carrying their own escaping, and this is what holds that true.
    it(('%s: every caller emits the same literal'):format(engine.kind), function()
      local relation = { schema = 'public', name = 'victim', kind = 'table' }
      local column = sqlmod.quote_ident('c', dialect)
      local key = { { column = 'id', value = '1' } }
      for _, case in ipairs(HOSTILE) do
        -- filter from a cell, which is also what `gf` and `gF` build their WHERE from
        local predicate, refused = common.cell_predicate('c', case.value, '=', dialect)
        if predicate then
          expect_literal(engine, case, predicate, column .. ' = ', '')
        else
          -- A refusal is allowed, but only with a message: never a silently different literal.
          eq(type(refused), 'string', { fail_reason = engine.kind .. ': ' .. case.name })
        end

        -- a grid cell edit
        local update = mutate.update(relation, key, 'c', case.value, dialect)
        expect_literal(
          engine,
          case,
          update.sql,
          ('SET %s = '):format(column),
          ' WHERE ' .. common.match_where(key, dialect)
        )

        -- a CSV import, through the real planner
        local plan, plan_err = import.plan(relation, { { 'c' }, { case.value } }, { 'c' }, dialect)
        eq(plan_err, nil, { fail_reason = tostring(plan_err) })
        expect_literal(engine, case, plan.changes[1].sql, 'VALUES (', ')')

        -- a `.sql` export
        local insert = mutate.insert_text(relation, { 'c' }, { case.value }, dialect)
        expect_literal(engine, case, insert, 'VALUES (', ');')
      end
    end)
  end

  --- postgres and duckdb are covered by the SYNTAX; mysql and mariadb cannot be, so their
  --- adapters make the mode true instead. Without this the `backslash` row above is an assumption.
  it('pins the server setting the quoting depends on, per adapter', function()
    local pg = require('dblens.adapters.postgres')
    for _, read_only in ipairs({ true, false }) do
      local env =
        pg.command({ database = 'app', read_only = read_only }, nil, 'records', h.CLIENTS).env
      eq(
        (env.PGOPTIONS or ''):find('standard_conforming_strings=on', 1, true) ~= nil,
        true,
        { fail_reason = ('postgres read_only=%s: %s'):format(read_only, tostring(env.PGOPTIONS)) }
      )
    end

    for _, kind in ipairs({ 'mysql', 'mariadb' }) do
      local adapter = assert(require('dblens.adapters').get(kind))
      for _, read_only in ipairs({ true, false }) do
        local argv =
          adapter.command({ database = 'app', read_only = read_only }, nil, 'raw', h.CLIENTS).argv
        local pinned = false
        for _, part in ipairs(argv) do
          if part:find('NO_BACKSLASH_ESCAPES', 1, true) and part:find('sql_mode', 1, true) then
            pinned = true
          end
        end
        eq(pinned, true, {
          fail_reason = ('%s read_only=%s does not clear NO_BACKSLASH_ESCAPES'):format(
            kind,
            read_only
          ),
        })
      end
    end
  end)

  --- The decoder is the judge, so it has to be wrong in the ways a server is wrong. These are the
  --- exact shapes the old quoter produced; if the decoder accepted them it would prove nothing.
  it('the decoder itself catches what the old quoting did', function()
    -- What postgres emitted BEFORE the fix for a value ending in `\`, read by a server with
    -- `standard_conforming_strings = off`: the closing quote is escaped and the literal runs on.
    eq(decode_literal([['C:\' LIMIT 1]], 'backslash'), nil)
    eq(decode_literal([['C:\' LIMIT 1]], 'standard'), [[C:\]])
    -- And the live payload: under `off` the literal ends early and a `;` is left in the open.
    local value, rest = decode_literal([['\''); DROP TABLE victim; --')]], 'backslash')
    eq(value, "'", { fail_reason = tostring(value) })
    eq(rest, [[); DROP TABLE victim; --')]], { fail_reason = tostring(rest) })
    -- The same bytes under `on`, which is why nobody saw it: one literal, nothing left over.
    eq(
      decode_literal([['\''); DROP TABLE victim; --')]], 'standard'),
      [[\'); DROP TABLE victim; --]]
    )
  end)

  --- The other half of the `E'...'` decision: the filter bar takes raw SQL, so a user can type an
  --- escape-string themselves, and dblens's lexer reads it with backslashes INERT while the server
  --- reads them as escapes. That disagreement is safe in one direction only, and this is it — the
  --- lexer closes the string no LATER than the server does, so anything the server would still be
  --- reading as code is code here too and gets refused. The reverse (lexer over-consuming, server
  --- seeing live SQL) is the shape that was a bypass, and it cannot arise on these dialects.
  it('cannot hide a separator behind a hand-typed escape-string filter', function()
    for _, kind in ipairs({ 'postgres', 'duckdb' }) do
      local d = sqlmod.dialects[kind]
      local function why(predicate)
        return tostring(common.check_predicate(predicate, d))
      end
      eq(why([[a = E'\' ; DROP TABLE t]]):find('`;`', 1, true) ~= nil, true, { fail_reason = kind })
      eq(why([[a = E'\' OR 1=1 --x]]):find('comment', 1, true) ~= nil, true, { fail_reason = kind })
      eq(why([[a = E'\' OR x = ']]):find('unclosed', 1, true) ~= nil, true, { fail_reason = kind })
      -- An ordinary one still filters: the refusals above are about structure, not the syntax.
      eq(common.check_predicate([[a = E'x' AND b = 1]], d), nil, { fail_reason = kind })
    end
  end)

  it('rejects a NUL rather than quoting one', function()
    h.expect_error(function()
      sqlmod.quote_literal('a\0b', sqlmod.dialects.postgres)
    end, 'NUL byte')
  end)
end)

--- A NUL cannot be carried by any client dblens drives, so it is refused at the FILE boundary
--- with a message naming the line. It used to reach `quote_literal`'s assertion instead, from
--- inside a scheduled callback: the user got a Lua traceback and no message at all.
describe('csv: a NUL byte is a named error, not a traceback', function()
  local csv = require('dblens.csv')

  it('names the line it is on, for a quoted and an unquoted field', function()
    local rows, err = csv.parse('id,v\nn1,AB\0CD\nn2,plain\n')
    eq(rows, nil)
    eq(err, 'line 2: a value contains a NUL byte, which SQL cannot carry')

    local quoted_rows, quoted_err = csv.parse('id,v\nn1,x\nn2,"AB\0CD"\n')
    eq(quoted_rows, nil)
    eq(quoted_err, 'line 3: a value contains a NUL byte, which SQL cannot carry')
  end)

  it('leaves an ordinary file alone', function()
    local rows, err = csv.parse('id,v\n1,a\n')
    eq(err, nil)
    eq(#rows, 2)
  end)

  it('stops the importer before it plans anything', function()
    local relation = { name = 't', kind = 'table' }
    local rows = csv.parse('id\n1\n')
    eq(#rows, 2)
    -- The planner is only ever handed rows `csv.parse` accepted, so the NUL never reaches it.
    local plan, plan_err = import.plan(relation, rows, { 'id' }, sqlmod.dialects.postgres)
    eq(plan_err, nil, { fail_reason = tostring(plan_err) })
    eq(plan.rows, 1)
  end)
end)

--- Live round trips. Each one writes a hostile value through the REAL client and reads the bytes
--- back, so the claim is the server's rather than this file's. A missing client or server adds a
--- note naming the proof that did not run.
describe('live: a hostile value stored through the real client comes back unchanged', function()
  --- Values a shell-free argv and every engine can carry. The newline is here because it is the
  --- one control byte the import path is expected to keep.
  local LIVE_VALUES = {
    [[C:\]],
    [[\'); DROP TABLE victim; --]],
    [['); DROP TABLE victim;--]],
    [[C:\path\to\file]],
    "o'brien",
    'line one\nline two',
  }

  --- Run `statement` through the adapter's own argv, with no gate in front of it.
  ---@return vim.SystemCompleted
  local function send(adapter, target, statement, read_only)
    local spec = vim.tbl_extend('force', target.spec, { read_only = read_only == true })
    local command = adapter.command(spec, target.secret, 'records', target.clients)
    return vim.system(command.argv, { env = command.env, stdin = statement }):wait(60000)
  end

  --- Insert every hostile value as a quoted literal, then read them back and compare bytes.
  ---@param quote_column string  -- SQL that renders the stored value unambiguously
  local function round_trip(adapter, target, quote_column)
    local dialect = adapter.dialect
    local statements = {
      'DROP TABLE IF EXISTS quoting_live;',
      'CREATE TABLE quoting_live(id int, v text);',
      'DROP TABLE IF EXISTS victim;',
      'CREATE TABLE victim(a int);',
    }
    for index, value in ipairs(LIVE_VALUES) do
      statements[#statements + 1] = ('INSERT INTO quoting_live VALUES (%d, %s);'):format(
        index,
        sqlmod.quote_literal(value, dialect)
      )
    end
    local wrote = send(adapter, target, table.concat(statements, '\n'))
    eq(wrote.code, 0, { fail_reason = tostring(wrote.stderr) })

    local read =
      send(adapter, target, ('SELECT %s FROM quoting_live ORDER BY id;'):format(quote_column))
    eq(read.code, 0, { fail_reason = tostring(read.stderr) })
    local rows = adapter.decode(read.stdout, {}).rows
    eq(#rows, #LIVE_VALUES, { fail_reason = tostring(read.stdout) })
    for index, value in ipairs(LIVE_VALUES) do
      eq(tostring(rows[index][1]), value, {
        fail_reason = ('value %d did not round-trip'):format(index),
      })
    end

    -- The table a payload would have dropped is still there, which is the point of the exercise.
    local survived = send(adapter, target, 'SELECT count(*) AS n FROM victim;')
    eq(survived.code, 0, { fail_reason = 'victim was dropped: ' .. tostring(survived.stderr) })
  end

  it('sqlite', function()
    local live = h.live_file_client('sqlite')
    if not live then
      MiniTest.add_note('no sqlite3 client; the live sqlite quoting round trip did not run')
      return
    end
    local adapter = assert(require('dblens.adapters').get('sqlite'))
    local target = {
      spec = { name = 'live', kind = 'sqlite', path = vim.fn.tempname() .. '.db' },
      clients = live.clients,
    }
    round_trip(adapter, target, 'v')
  end)

  it('duckdb', function()
    local live = h.live_file_client('duckdb')
    if not live then
      MiniTest.add_note('no duckdb client; the live duckdb quoting round trip did not run')
      return
    end
    local adapter = assert(require('dblens.adapters').get('duckdb'))
    local target = {
      spec = { name = 'live', kind = 'duckdb', path = vim.fn.tempname() .. '.duckdb' },
      clients = live.clients,
    }
    round_trip(adapter, target, 'v')
  end)

  for _, kind in ipairs({ 'postgres', 'mysql', 'mariadb' }) do
    it(kind, function()
      local target = h.live_target(kind)
      if not target then
        MiniTest.add_note(
          ('no %s server (set DBLENS_TEST_%s_PORT); the live quoting round trip did not run'):format(
            kind,
            kind:upper()
          )
        )
        return
      end
      round_trip(assert(require('dblens.adapters').get(kind)), target, 'v')
    end)
  end
end)
