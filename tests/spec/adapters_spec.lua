--- Adapters are pure descriptions of a client: argv, decoding, and statement text. Everything
--- here runs without a database. Two invariants get the most attention: a secret never reaches
--- argv, and generated SQL is quoted so a hostile object name cannot escape its delimiter.
local h = require('helpers')
local adapters = require('dblens.adapters')
local common = require('dblens.adapters.common')
local sql = require('dblens.sql')
local protocol = require('dblens.protocol')

local eq, expect_error = h.eq, h.expect_error
local SECRET = 'hunter2-s3cr3t'
local CLIENTS = { sqlite = 'sqlite3', postgres = 'psql', mysql = 'mysql' }

--- A relation whose name and schema both fight the quoting.
local WEIRD = { schema = 'we.ird', name = 'my "weird" tbl', kind = 'table' }

local function get(kind)
  local adapter, err = adapters.get(kind)
  assert(adapter, tostring(err))
  return adapter
end

describe('adapters.normalize', function()
  it('accepts the canonical kinds', function()
    for _, kind in ipairs({ 'sqlite', 'postgres', 'mysql', 'mariadb', 'duckdb', 'mssql' }) do
      eq(adapters.normalize(kind), kind)
    end
  end)

  it('resolves the documented aliases', function()
    local ALIASES = {
      sqlite3 = 'sqlite',
      postgresql = 'postgres',
      pg = 'postgres',
      psql = 'postgres',
      maria = 'mariadb',
      duck = 'duckdb',
      sqlserver = 'mssql',
      ['sql-server'] = 'mssql',
      tsql = 'mssql',
      sqlcmd = 'mssql',
    }
    for alias, canonical in pairs(ALIASES) do
      eq(adapters.normalize(alias), canonical, { fail_reason = 'alias ' .. alias })
    end
  end)

  --- `mariadb` used to resolve to the mysql adapter. It is its own kind now because the client
  --- binary differs, and a spec that said `mariadb` must reach the adapter that drives `mariadb`.
  it('resolves mariadb to its own adapter, not to mysql', function()
    eq(adapters.normalize('mariadb'), 'mariadb')
    eq(get('mariadb') == get('mysql'), false)
    eq(get('mariadb').kind, 'mariadb')
  end)

  it('is case-insensitive', function()
    eq(adapters.normalize('PostgreSQL'), 'postgres')
    eq(adapters.normalize('MariaDB'), 'mariadb')
    eq(adapters.normalize('SQLServer'), 'mssql')
  end)

  it('returns nil for an unknown kind or a non-string', function()
    eq(adapters.normalize('oracle'), nil)
    eq(adapters.normalize(''), nil)
    eq(adapters.normalize(42), nil)
    eq(adapters.normalize(nil), nil)
  end)
end)

describe('adapters.get', function()
  it('returns the adapter whose kind matches the registry key', function()
    for _, kind in ipairs(adapters.kinds()) do
      local adapter, err = adapters.get(kind)
      eq(err, nil)
      eq(adapter.kind, kind)
      eq(type(adapter.command), 'function')
      eq(type(adapter.decode), 'function')
      eq(type(adapter.validate), 'function')
    end
  end)

  it('returns the same instance for an alias and for a repeat lookup', function()
    eq(get('pg') == get('postgres'), true)
    eq(get('sqlite') == get('sqlite3'), true)
  end)

  it('explains an unknown kind and lists the known ones', function()
    local adapter, err = adapters.get('oracle')
    eq(adapter, nil)
    eq(type(err), 'string')
    eq(err:find('unknown database kind `oracle`', 1, true) ~= nil, true)
    eq(err:find('mysql, postgres, sqlite', 1, true) ~= nil, true)
  end)

  it('lists its kinds in a stable order', function()
    eq(adapters.kinds(), { 'duckdb', 'mariadb', 'mssql', 'mysql', 'postgres', 'sqlite' })
  end)

  --- The declaration is what the UI, the docs and `:checkhealth` read to tell a strong LOCKED
  --- connection from a best-effort one. An adapter that omitted it would be shown as if it were
  --- strong, so `adapters.get` refuses to load one.
  it('makes every adapter declare how its read-only mode is enforced', function()
    local MECHANISMS =
      { ['file-open'] = true, ['session-and-transaction'] = true, classifier = true }
    for _, kind in ipairs(adapters.kinds()) do
      local enforcement = get(kind).read_only_enforcement
      eq(MECHANISMS[enforcement.mechanism], true, { fail_reason = kind .. ': unknown mechanism' })
      eq(#enforcement.summary > 0, true, { fail_reason = kind .. ': empty summary' })
      local strong = enforcement.strength == 'strong'
      eq(strong, enforcement.mechanism ~= 'classifier', {
        fail_reason = ('%s: a classifier-only lock must not be called strong'):format(kind),
      })
    end
  end)

  --- Named one at a time rather than derived, so promoting an engine to `strong` is a deliberate
  --- edit to this list and not a side effect of an adapter change.
  it('holds mssql, and only mssql, to best-effort', function()
    eq(get('mssql').read_only_enforcement.strength, 'best-effort')
    for _, kind in ipairs({ 'sqlite', 'duckdb', 'postgres', 'mysql', 'mariadb' }) do
      eq(get(kind).read_only_enforcement.strength, 'strong', { fail_reason = kind })
    end
  end)
end)

describe('adapter.validate', function()
  it('rejects a sqlite spec with no path', function()
    local sqlite = get('sqlite')
    eq(sqlite.validate({}), 'sqlite connection needs a `path`')
    eq(sqlite.validate({ path = '' }), 'sqlite connection needs a `path`')
    eq(sqlite.validate({ path = 42 }), 'sqlite connection needs a `path`')
    eq(sqlite.validate({ path = '/tmp/x.db' }), nil)
  end)

  it('rejects a postgres or mysql spec with no database', function()
    for _, kind in ipairs({ 'postgres', 'mysql' }) do
      local adapter = get(kind)
      eq(adapter.validate({}), kind .. ' connection needs a `database`')
      eq(adapter.validate({ database = '' }), kind .. ' connection needs a `database`')
      eq(adapter.validate({ database = 'app' }), nil)
    end
  end)

  it('rejects a non-numeric port', function()
    for _, kind in ipairs({ 'postgres', 'mysql' }) do
      local adapter = get(kind)
      eq(adapter.validate({ database = 'app', port = '5432' }), kind .. ' `port` must be a number')
      eq(adapter.validate({ database = 'app', port = 5432 }), nil)
    end
  end)

  it('describes a connection without leaking a secret', function()
    eq(
      get('postgres').describe({ user = 'u', host = 'h', port = 5433, database = 'd' }),
      'u@h:5433/d'
    )
    eq(get('mysql').describe({ database = 'd' }), '$USER@localhost:3306/d')
    eq(get('sqlite').describe({ path = '/tmp/x.db' }), '/tmp/x.db')
  end)
end)

describe('postgres.command', function()
  local postgres = get('postgres')

  it('builds the documented argv for raw mode', function()
    local cmd = postgres.command({ database = 'app' }, nil, 'raw', CLIENTS)
    eq(cmd.argv, {
      'psql',
      '-X',
      '-q',
      '-v',
      'ON_ERROR_STOP=1',
      '-P',
      'pager=off',
      '-P',
      'footer=off',
      '-A',
      '-t',
      '-d',
      'app',
      '-f',
      '-',
    })
    eq(cmd.env, { PGCONNECT_TIMEOUT = '10' })
  end)

  it('asks for quoted CSV in records mode', function()
    local cmd = postgres.command({ database = 'app' }, nil, 'records', CLIENTS)
    -- Control-character framing was breakable by a value holding one of the separators; CSV
    -- quotes anything ambiguous, so only the NULL marker stays a convention.
    eq(h.has(cmd.argv, '--csv'), true)
    eq(h.has(cmd.argv, 'null=' .. protocol.NULL_SENTINEL), true)
    eq(h.flag_value(cmd.argv, '-F'), nil)
    eq(h.flag_value(cmd.argv, '-R'), nil)
    eq(h.has(cmd.argv, '-t'), false)
    -- `-f -` is what makes psql prefix an error with the script line number.
    eq(h.flag_value(cmd.argv, '-f'), '-')
  end)

  it('passes host, port and user as flags and takes the binary from the client table', function()
    local cmd = postgres.command(
      { host = 'db.internal', port = 5433, user = 'ada', database = 'app' },
      nil,
      'raw',
      {
        postgres = '/opt/bin/psql',
      }
    )
    eq(cmd.argv[1], '/opt/bin/psql')
    eq(h.flag_value(cmd.argv, '-h'), 'db.internal')
    eq(h.flag_value(cmd.argv, '-p'), '5433')
    eq(h.flag_value(cmd.argv, '-U'), 'ada')
    eq(h.flag_value(cmd.argv, '-d'), 'app')
  end)

  it('omits host, port and user when the spec has none', function()
    local cmd = postgres.command({ database = 'app' }, nil, 'raw', CLIENTS)
    eq(h.has(cmd.argv, '-h'), false)
    eq(h.has(cmd.argv, '-p'), false)
    eq(h.has(cmd.argv, '-U'), false)
  end)

  it('puts the password in PGPASSWORD and never in argv', function()
    local cmd =
      postgres.command({ host = 'h', user = 'u', database = 'app' }, SECRET, 'records', CLIENTS)
    eq(cmd.env.PGPASSWORD, SECRET)
    eq(h.leaks(cmd.argv, SECRET), false)
  end)

  it('carries sslmode in the environment', function()
    local cmd = postgres.command({ database = 'app', sslmode = 'require' }, nil, 'raw', CLIENTS)
    eq(cmd.env.PGSSLMODE, 'require')
    eq(h.has(cmd.argv, 'require'), false)
  end)
end)

describe('mysql.command', function()
  local mysql = get('mysql')

  it('builds the documented argv for both modes', function()
    local records = mysql.command({ database = 'app' }, nil, 'records', CLIENTS)
    eq(records.argv, {
      'mysql',
      '--default-character-set=utf8mb4',
      '--connect-timeout=10',
      '--local-infile=0',
      '--xml',
      'app',
    })
    local raw = mysql.command({ database = 'app' }, nil, 'raw', CLIENTS)
    eq(raw.argv, {
      'mysql',
      '--default-character-set=utf8mb4',
      '--connect-timeout=10',
      '--local-infile=0',
      '--batch',
      'app',
    })
    eq(raw.env, nil)
  end)

  it('passes host, port and user as flags, with the database last', function()
    local cmd = mysql.command(
      { host = 'db', port = 3307, user = 'ada', database = 'app' },
      nil,
      'records',
      {
        mysql = '/opt/bin/mysql',
      }
    )
    eq(cmd.argv[1], '/opt/bin/mysql')
    eq(h.flag_value(cmd.argv, '-h'), 'db')
    eq(h.flag_value(cmd.argv, '-P'), '3307')
    eq(h.flag_value(cmd.argv, '-u'), 'ada')
    eq(cmd.argv[#cmd.argv], 'app')
  end)

  it('puts the password in MYSQL_PWD and never in argv', function()
    local cmd =
      mysql.command({ host = 'db', user = 'ada', database = 'app' }, SECRET, 'records', CLIENTS)
    eq(cmd.env, { MYSQL_PWD = SECRET })
    eq(h.leaks(cmd.argv, SECRET), false)
    -- `-p<pass>` is the classic mistake: it would show up in `ps` for every user on the box.
    eq(h.has(cmd.argv, '-p'), false)
  end)
end)

describe('sqlite.command', function()
  local sqlite = get('sqlite')

  it('asks for the record protocol in records mode only', function()
    local records = sqlite.command({ path = '/tmp/x.db' }, nil, 'records', CLIENTS)
    local expected = {
      'sqlite3',
      '-batch',
      '-bail',
      '-safe',
      '-ascii',
      '-header',
      '-nullvalue',
      protocol.NULL_SENTINEL,
      '/tmp/x.db',
    }
    eq(records.argv, expected)
    local raw = sqlite.command({ path = '/tmp/x.db' }, nil, 'raw', CLIENTS)
    -- `-bail` makes the batch atomic; without it sqlite3 skips the failing statement and still
    -- runs the trailing COMMIT. `-safe` refuses `.shell`, `.load`, `.import` and ATTACH.
    eq(raw.argv, { 'sqlite3', '-batch', '-bail', '-safe', '/tmp/x.db' })
    eq(raw.env, nil)
  end)

  it('expands the database path and takes the binary from the client table', function()
    local cmd = sqlite.command({ path = '~/db/x.db' }, nil, 'raw', { sqlite = '/opt/bin/sqlite3' })
    eq(cmd.argv[1], '/opt/bin/sqlite3')
    eq(cmd.argv[#cmd.argv], vim.fn.expand('~/db/x.db'))
    eq(cmd.argv[#cmd.argv]:find('~', 1, true), nil)
  end)

  it('ignores a secret entirely, since sqlite has no authentication', function()
    local cmd = sqlite.command({ path = '/tmp/x.db' }, SECRET, 'records', CLIENTS)
    eq(h.leaks(cmd, SECRET), false)
    eq(cmd.env, nil)
  end)
end)

describe('no adapter puts a secret in argv', function()
  it('holds for every adapter and mode', function()
    local specs = {
      sqlite = { path = '/tmp/x.db' },
      postgres = { host = 'h', port = 5432, user = 'u', database = 'app' },
      mysql = { host = 'h', port = 3306, user = 'u', database = 'app' },
    }
    for kind, spec in pairs(specs) do
      for _, mode in ipairs({ 'records', 'raw' }) do
        local cmd = get(kind).command(spec, SECRET, mode, CLIENTS)
        eq(
          h.leaks(cmd.argv, SECRET),
          false,
          { fail_reason = ('secret in %s argv (%s)'):format(kind, mode) }
        )
      end
    end
  end)
end)

describe('adapter statement builders', function()
  it('quotes a hostile relation name for every dialect', function()
    eq(
      get('sqlite').sql.page({ name = WEIRD.name }, { limit = 10, offset = 0 }),
      'SELECT * FROM "my ""weird"" tbl" LIMIT 10 OFFSET 0'
    )
    eq(
      get('postgres').sql.page(WEIRD, { limit = 10, offset = 0 }),
      'SELECT * FROM "we.ird"."my ""weird"" tbl" LIMIT 10 OFFSET 0'
    )
    eq(
      get('mysql').sql.page(WEIRD, { limit = 10, offset = 0 }),
      'SELECT * FROM `we.ird`.`my "weird" tbl` LIMIT 10 OFFSET 0'
    )
    eq(
      get('mysql').sql.page({ name = 'ba`ck' }, { limit = 1, offset = 0 }),
      'SELECT * FROM `ba``ck` LIMIT 1 OFFSET 0'
    )
  end)

  it('keeps a dotted schema inside one identifier instead of splitting it', function()
    local statement = get('postgres').sql.count(WEIRD)
    eq(statement, 'SELECT count(*) AS n FROM "we.ird"."my ""weird"" tbl"')
    -- Re-lexing the result must see exactly two identifiers, with both hostile names intact.
    local tokens = sql.tokens(statement)
    local schema, dot, name = tokens[#tokens - 2], tokens[#tokens - 1], tokens[#tokens]
    eq({ schema.type, dot.text, name.type }, { 'ident', '.', 'ident' })
    eq(schema.value, 'we.ird')
    eq(name.value, 'my "weird" tbl')
  end)

  it('escapes a literal in the catalog queries', function()
    eq(get('postgres').sql.relations("s'x"):find("'s''x'", 1, true) ~= nil, true)
    eq(get('mysql').sql.relations("s'x"):find("'s''x'", 1, true) ~= nil, true)
    eq(get('sqlite').sql.ddl({ name = "o'brien" }):find("'o''brien'", 1, true) ~= nil, true)
    eq(
      get('sqlite').sql.columns({ name = 'my "weird" tbl' }):find([['my "weird" tbl']], 1, true)
        ~= nil,
      true
    )
  end)

  it('phrases DDL per client capability', function()
    eq(get('mysql').sql.ddl(WEIRD), 'SHOW CREATE TABLE `we.ird`.`my "weird" tbl`')
    eq(get('postgres').sql.ddl(WEIRD), nil)
    eq(get('postgres').caps.ddl, 'reconstructed')
    eq(get('sqlite').sql.schemas(), nil)
    eq(get('sqlite').caps.schemas, false)
  end)

  it('phrases EXPLAIN per client, and refuses ANALYZE where it is unsupported', function()
    eq(get('postgres').sql.explain('SELECT 1', false), 'EXPLAIN SELECT 1')
    eq(get('postgres').sql.explain('SELECT 1', true), 'EXPLAIN (ANALYZE, BUFFERS) SELECT 1')
    eq(get('mysql').sql.explain('SELECT 1', true), 'EXPLAIN ANALYZE SELECT 1')
    eq(get('sqlite').sql.explain('SELECT 1', false), 'EXPLAIN QUERY PLAN SELECT 1')
    expect_error(function()
      get('sqlite').sql.explain('SELECT 1', true)
    end, 'EXPLAIN ANALYZE is unsupported')
  end)

  it('reports rows affected only where the client can', function()
    eq(get('sqlite').sql.affected(), 'SELECT changes() AS affected')
    eq(get('mysql').sql.affected(), 'SELECT ROW_COUNT() AS affected')
    eq(get('postgres').sql.affected(), nil)
  end)
end)

describe('common.check_predicate', function()
  it('accepts an ordinary predicate', function()
    eq(common.check_predicate('id > 5'), nil)
    eq(common.check_predicate("name = 'x' OR id IN (SELECT id FROM other)"), nil)
    eq(common.check_predicate('created_at BETWEEN a AND b'), nil)
  end)

  it('accepts a `;` that lives inside a string literal', function()
    eq(common.check_predicate("id > 5 AND name = 'a;b'"), nil)
    eq(common.check_predicate("name = ';'"), nil)
  end)

  it('accepts nothing at all', function()
    eq(common.check_predicate(nil), nil)
    eq(common.check_predicate(''), nil)
    eq(common.check_predicate('   \n '), nil)
  end)

  it('rejects a second statement smuggled in with a `;`', function()
    eq(common.check_predicate('1=1; DROP TABLE t'), 'filter must not contain `;`')
    eq(common.check_predicate('id = 1; DELETE FROM t'), 'filter must not contain `;`')
  end)

  it('rejects a write verb where a nested statement could begin', function()
    eq(common.check_predicate('id=1 AND (DELETE FROM t)'), 'filter must not contain `DELETE`')
    eq(common.check_predicate('x IN (TRUNCATE TABLE t)'), 'filter must not contain `TRUNCATE`')
    eq(common.check_predicate('x = 1; '), 'filter must not contain `;`')
    eq(common.check_predicate("id > 5 AND name = 'a;b'"), nil)
    eq(common.check_predicate('"update" > 5'), nil)
  end)

  --- The predicate is spliced into a WHERE clause, so with no `;`, comment or backslash it
  --- cannot become a second statement. A verb at the head is a typo, not a threat: it reaches
  --- the server and comes back as a syntax error, which is a clearer message than a guess here.
  it('leaves a bare write statement to the server rather than guessing at the head word', function()
    eq(common.check_predicate('DELETE FROM t'), nil)
    eq(common.check_predicate('comment IS NOT NULL'), nil)
    eq(common.check_predicate("REPLACE(a, 'x', 'y') = 'z'"), nil)
  end)
end)

describe('common.qualify', function()
  it('quotes both parts and drops an empty schema', function()
    eq(common.qualify({ name = 't' }, sql.dialects.postgres), '"t"')
    eq(common.qualify({ schema = '', name = 't' }, sql.dialects.postgres), '"t"')
    eq(common.qualify({ schema = 's', name = 't' }, sql.dialects.mysql), '`s`.`t`')
  end)

  it('refuses a relation with no name', function()
    expect_error(function()
      common.qualify({ schema = 's' }, sql.dialects.postgres)
    end, 'relation needs a name')
  end)
end)

describe('common.page', function()
  local dialect = sql.dialects.standard

  it('composes WHERE, ORDER BY, LIMIT and OFFSET in that order', function()
    eq(
      common.page({ schema = 's', name = 't' }, {
        limit = 25,
        offset = 50,
        where = 'a = 1',
        order_by = { column = 'c d', desc = true },
      }, dialect),
      'SELECT * FROM "s"."t" WHERE a = 1 ORDER BY "c d" DESC LIMIT 25 OFFSET 50'
    )
  end)

  it('omits the clauses it was not given', function()
    eq(
      common.page({ name = 't' }, { limit = 10, offset = 0 }, dialect),
      'SELECT * FROM "t" LIMIT 10 OFFSET 0'
    )
    eq(
      common.page({ name = 't' }, { limit = 10, offset = 0, where = '  ' }, dialect),
      'SELECT * FROM "t" LIMIT 10 OFFSET 0'
    )
  end)

  it('sorts ascending unless told otherwise, and quotes the sort column', function()
    eq(
      common.page({ name = 't' }, { limit = 1, offset = 0, order_by = { column = 'a"b' } }, dialect),
      'SELECT * FROM "t" ORDER BY "a""b" ASC LIMIT 1 OFFSET 0'
    )
  end)

  it('refuses a non-positive limit or a negative offset', function()
    expect_error(function()
      common.page({ name = 't' }, { limit = 0, offset = 0 }, dialect)
    end, 'limit must be positive')
    expect_error(function()
      common.page({ name = 't' }, { limit = 10, offset = -1 }, dialect)
    end, 'offset must not be negative')
  end)

  it('refuses to splice an unsafe predicate', function()
    expect_error(function()
      common.page({ name = 't' }, { limit = 10, offset = 0, where = '1=1; DROP TABLE t' }, dialect)
    end, 'unsafe predicate reached SQL generation')
  end)
end)

describe('common.count', function()
  local dialect = sql.dialects.standard

  it('counts with and without a predicate', function()
    eq(common.count({ name = 't' }, nil, dialect), 'SELECT count(*) AS n FROM "t"')
    eq(
      common.count({ schema = 's', name = 't' }, ' a = 1 ', dialect),
      'SELECT count(*) AS n FROM "s"."t" WHERE a = 1'
    )
  end)

  it('refuses to splice an unsafe predicate', function()
    expect_error(function()
      common.count({ name = 't' }, 'a = 1; DROP TABLE t', dialect)
    end, 'unsafe predicate reached SQL generation')
  end)
end)

describe('common.match_where', function()
  local dialect = sql.dialects.standard

  it('renders IS NULL for a NULL value and a quoted literal otherwise', function()
    eq(
      common.match_where({
        { column = 'id', value = 7 },
        { column = 'note', value = vim.NIL },
        { column = 'name', value = "o'brien" },
      }, dialect),
      '"id" = \'7\' AND "note" IS NULL AND "name" = \'o\'\'brien\''
    )
  end)

  it('treats a missing value as NULL', function()
    eq(common.match_where({ { column = 'a' } }, dialect), '"a" IS NULL')
  end)

  it('quotes a hostile column name', function()
    eq(common.match_where({ { column = 'a"b', value = '1' } }, dialect), '"a""b" = \'1\'')
  end)

  it('refuses an empty value list', function()
    expect_error(function()
      common.match_where({}, dialect)
    end, 'refusing to build an empty predicate')
  end)
end)

describe('mysql.decode', function()
  local mysql = get('mysql')

  local function resultset(body)
    return '<?xml version="1.0"?>\n'
      .. '<resultset statement="select" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
      .. body
      .. '\n</resultset>\n'
  end

  it('reads names and values from the first row', function()
    local decoded = mysql.decode(resultset(table.concat({
      '  <row>',
      '\t<field name="id">1</field>',
      '\t<field name="name">ada</field>',
      '  </row>',
      '  <row>',
      '\t<field name="id">2</field>',
      '\t<field name="name">grace</field>',
      '  </row>',
    }, '\n')))
    eq(decoded.columns, { 'id', 'name' })
    eq(decoded.rows, { { '1', 'ada' }, { '2', 'grace' } })
    eq(decoded.malformed, 0)
  end)

  it('reads a self-closing xsi:nil field as SQL NULL', function()
    local decoded = mysql.decode(
      resultset(
        '  <row>\n\t<field name="id">1</field>\n\t<field name="note" xsi:nil="true" />\n  </row>'
      )
    )
    eq(decoded.columns, { 'id', 'note' })
    eq(decoded.rows[1][1], '1')
    eq(decoded.rows[1][2], h.NULL)
  end)

  it('decodes the four-character string NULL as text, not as SQL NULL', function()
    local decoded = mysql.decode(resultset('  <row>\n\t<field name="note">NULL</field>\n  </row>'))
    eq(decoded.rows[1][1], 'NULL')
    h.neq(decoded.rows[1][1], h.NULL)
  end)

  it('unescapes named and numeric XML entities', function()
    local decoded = mysql.decode(
      resultset('<row><field name="v">&amp; &lt; &gt; &quot; &apos; &#38; &#x26;</field></row>')
    )
    eq(decoded.rows[1][1], [[& < > " ' & &]])
  end)

  it('leaves an unknown entity alone rather than dropping it', function()
    local decoded = mysql.decode(resultset('<row><field name="v">a&nope;b</field></row>'))
    eq(decoded.rows[1][1], 'a&nope;b')
  end)

  it('unescapes a column name too', function()
    eq(mysql.decode('<row><field name="a&amp;b">1</field></row>').columns, { 'a&b' })
  end)

  it('distinguishes an empty field from a NULL one', function()
    local decoded = mysql.decode('<row><field name="a"></field></row>')
    eq(decoded.rows[1][1], '')
    h.neq(decoded.rows[1][1], h.NULL)
  end)

  it('returns an empty result set for zero rows', function()
    local decoded = mysql.decode(resultset(''))
    eq(decoded.columns, {})
    eq(decoded.rows, {})
    eq(decoded.malformed, 0)
    eq(mysql.decode('').rows, {})
  end)

  it('keeps caller-supplied columns when the client printed no rows', function()
    eq(mysql.decode('', { columns = { 'id', 'name' } }).columns, { 'id', 'name' })
  end)

  it('pads a short row with NULL and counts it as malformed', function()
    local decoded = mysql.decode(table.concat({
      '<row><field name="a">1</field><field name="b">2</field></row>',
      '<row><field name="a">3</field></row>',
    }))
    eq(decoded.columns, { 'a', 'b' })
    eq(decoded.rows, { { '1', '2' }, { '3', h.NULL } })
    eq(decoded.malformed, 1)
  end)
end)

describe('postgres.estimate', function()
  local postgres = get('postgres')

  it('plans without executing and reads the planner row count', function()
    local estimate = postgres.estimate('DELETE FROM t WHERE id > 5')
    eq(estimate.sql, 'EXPLAIN (FORMAT JSON) DELETE FROM t WHERE id > 5')
    eq(estimate.mode, 'raw')
    eq(estimate.sql:find('ANALYZE', 1, true), nil)
    local payload = [==[
[
  {
    "Plan": {
      "Node Type": "Delete",
      "Relation Name": "t",
      "Startup Cost": 0.00,
      "Total Cost": 25.88,
      "Plan Rows": 1234.7,
      "Plan Width": 6,
      "Plans": [
        { "Node Type": "Seq Scan", "Relation Name": "t", "Plan Rows": 1234.7 }
      ]
    },
    "Query Identifier": 42
  }
]
]==]
    eq(estimate.parse(nil, payload), 1234)
  end)

  it('returns nil rather than raising on malformed or unexpected JSON', function()
    local parse = postgres.estimate('SELECT 1').parse
    eq(parse(nil, '{oops'), nil)
    eq(parse(nil, ''), nil)
    eq(parse(nil, '[]'), nil)
    eq(parse(nil, '[{"Plan": {"Node Type": "Seq Scan"}}]'), nil)
    eq(parse(nil, '[{"Plan": {"Plan Rows": "many"}}]'), nil)
    eq(parse(nil, '"a string"'), nil)
  end)
end)

describe('mysql.estimate', function()
  it('reads the EXPLAIN `rows` column', function()
    local estimate = get('mysql').estimate('DELETE FROM t')
    eq(estimate.sql, 'EXPLAIN DELETE FROM t')
    eq(estimate.mode, 'records')
    local decoded = protocol.decode(h.wire({ h.record('id', 'rows'), h.record('1', '42') }))
    eq(estimate.parse(decoded), 42)
  end)

  it('returns nil when the column or the row is missing', function()
    local parse = get('mysql').estimate('SELECT 1').parse
    eq(parse({ columns = { 'id' }, rows = { { '1' } } }), nil)
    eq(parse({ columns = { 'rows' }, rows = {} }), nil)
  end)
end)

describe('mysql.decode result sets', function()
  local mysql = get('mysql')

  it('reads only the first result set', function()
    -- A CALL, or some SHOW variants, produce several. Their columns differ, so concatenating
    -- them aligned the later rows to the first set's headers.
    local xml = table.concat({
      '<resultset statement="call p()">',
      '<row><field name="a">1</field><field name="b">2</field></row>',
      '</resultset>',
      '<resultset statement="call p()">',
      '<row><field name="z">9</field></row>',
      '</resultset>',
    })
    local decoded = mysql.decode(xml)
    eq(decoded.columns, { 'a', 'b' })
    eq(decoded.rows, { { '1', '2' } })
    eq(decoded.malformed, 0)
  end)

  it('still reads a plain single result set', function()
    local xml = '<resultset><row><field name="a">1</field></row></resultset>'
    eq(mysql.decode(xml).rows, { { '1' } })
  end)
end)

describe('adapters: the transaction row guard', function()
  it('every adapter can build a statement that fails unless the count is 1', function()
    for _, kind in ipairs({ 'sqlite', 'postgres', 'mysql' }) do
      local adapter = get(kind)
      local statement = adapter.sql.assert_one('SELECT count(*) FROM t WHERE id = 1')
      eq(type(statement), 'string', { fail_reason = kind .. ' has no row-guard builder' })
      h.neq(statement:find('count(*)', 1, true), nil)
      expect_error(function()
        adapter.sql.assert_one('')
      end)
    end
  end)
end)
