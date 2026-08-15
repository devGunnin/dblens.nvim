--- MySQL / MariaDB adapter, driven through the `mysql` client.
---
--- Verified live against MySQL 8.4: the read-only session, the row guard, batch atomicity, XML
--- decoding, and that `system`/`source` are honoured from stdin in batch mode (see `command`).
---
--- Output uses `--xml` rather than the default tab format on purpose: the tab format prints SQL
--- NULL as the literal text `NULL`, which is indistinguishable from the four-character string
--- 'NULL'. XML marks NULL with `xsi:nil`, so cell values stay exact.
local common = require('dblens.adapters.common')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local dialect = sql.dialects.mysql

local function lit(value)
  return sql.quote_literal(value, dialect)
end

---@type dblens.Adapter
local M = {
  kind = 'mysql',
  label = 'MySQL',
  dialect = dialect,
  caps = {
    schemas = true,
    ddl = 'native',
    explain = true,
    explain_analyze = true,
    estimate_rows = true,
    ilike = false,
  },
  read_only_enforcement = {
    mechanism = 'session-and-transaction',
    strength = 'strong',
    summary = 'every locked run is sent inside `START TRANSACTION READ ONLY`, on a session '
      .. 'opened `SET SESSION TRANSACTION READ ONLY`; the server refuses the write',
  },
  fields = {
    { name = 'host', label = 'Host', default = 'localhost' },
    { name = 'port', label = 'Port', default = 3306 },
    { name = 'user', label = 'User' },
    { name = 'database', label = 'Database', required = true },
  },
}

--- Validation for both engines that drive this client. The mariadb adapter calls this rather than
--- keeping its own copy: the copy is what let the two rules below miss mariadb entirely.
---@param spec dblens.ConnectionSpec
---@param engine string  -- `mysql` or `mariadb`, for the message
---@return string? error
function M.validate_as(spec, engine)
  assert(type(engine) == 'string' and engine ~= '', 'mysql.validate_as: needs an engine name')
  if type(spec.database) ~= 'string' or spec.database == '' then
    return ('%s connection needs a `database`'):format(engine)
  end
  -- Same bare-name rule postgres and mssql carry. A database is a name, not a connection string,
  -- and this is what turns a mis-parsed URL into a clean drop instead of a wrong target.
  if spec.database:find('[%s=/:]') then
    return ('%s `database` must be a bare database name, not a connection string'):format(engine)
  end
  local problem = common.argv_field_problem(spec, engine, { 'host', 'user', 'database' })
  if problem then
    return problem
  end
  if spec.port ~= nil and type(spec.port) ~= 'number' then
    return ('%s `port` must be a number'):format(engine)
  end
  return nil
end

function M.validate(spec)
  return M.validate_as(spec, 'mysql')
end

function M.describe(spec)
  return ('%s@%s:%s/%s'):format(
    spec.user or '$USER',
    spec.host or 'localhost',
    spec.port or 3306,
    spec.database
  )
end

--- Statements every connection runs before dblens sends anything.
---
--- ONE `--init-command`, both settings inside it: the client keeps only the LAST occurrence of the
--- option, so passing two silently dropped the read-only switch (verified on 8.4 and MariaDB
--- 11.8 — `@@transaction_read_only` came back 0). Two statements in one are honoured on both.
---
--- Clearing `NO_BACKSLASH_ESCAPES` makes an assumption dblens cannot otherwise see TRUE: this
--- dialect doubles `\` when quoting a literal and frames strings the same way when it scans them,
--- and under that mode the server would both store the extra backslash and disagree with dblens
--- about where a string ends. The `,`-wrapping is what lets the flag be removed wherever it sits
--- in the list, MySQL's leading position included.
local CLEAR_NO_BACKSLASH_ESCAPES = "SET SESSION sql_mode = TRIM(BOTH ',' FROM "
  .. "REPLACE(CONCAT(',', @@SESSION.sql_mode, ','), ',NO_BACKSLASH_ESCAPES,', ','))"

---@param spec dblens.ConnectionSpec
---@return string
function M.init_command(spec)
  local statements = { CLEAR_NO_BACKSLASH_ESCAPES }
  if spec.read_only == true then
    table.insert(statements, 1, 'SET SESSION TRANSACTION READ ONLY')
  end
  return '--init-command=' .. table.concat(statements, '; ')
end

--- The password goes through MYSQL_PWD, never argv, which would expose it in the process list.
---
--- `SET SESSION TRANSACTION READ ONLY` (see `init_command`) and the transaction wrap are BOTH
--- load-bearing, and neither alone is enough. Verified live on MySQL 8.4 and MariaDB 11.8: inside
--- a bare `START TRANSACTION READ ONLY`, `CREATE TABLE` and `DROP TABLE` SUCCEED -- DDL commits
--- the transaction implicitly and then runs outside it. The SESSION setting is what refuses those
--- (ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION, 1792); the transaction is what a `SET` in the same
--- run cannot undo. Removing either one opens a hole the other does not cover.
---
--- `--local-infile=0` blocks `LOAD DATA LOCAL INFILE`, which reads a file on THIS machine. There
--- is no client flag that disables `system`/`source` (`--skip-named-commands` still honours them
--- at the head of a line, verified on 8.4), so `sql.client_meta_problem` refuses those instead.
---
--- The database is passed as `--database=<name>`, not as the trailing positional it used to be.
--- `my_getopt` splits a long option at its FIRST `=`, so the value is bound to the option and can
--- never be re-read as a flag however it is spelled. Shared with the mariadb adapter, which drives
--- the same client with the same argv: two copies is how the missing validation reached mariadb.
---@param spec dblens.ConnectionSpec
---@param mode 'records'|'raw'
---@param binary string
---@return string[]
function M.build_argv(spec, mode, binary)
  assert(type(binary) == 'string' and binary ~= '', 'mysql.build_argv: no client configured')
  assert(
    common.argv_field_problem(spec, 'mysql', { 'host', 'user', 'database' }) == nil,
    'mysql.build_argv: an option-like connection field reached argv'
  )
  local argv =
    { binary, '--default-character-set=utf8mb4', '--connect-timeout=10', '--local-infile=0' }
  argv[#argv + 1] = M.init_command(spec)
  argv[#argv + 1] = mode == 'records' and '--xml' or '--batch'
  if spec.host then
    vim.list_extend(argv, { '-h', spec.host })
  end
  if spec.port then
    vim.list_extend(argv, { '-P', tostring(spec.port) })
  end
  if spec.user then
    vim.list_extend(argv, { '-u', spec.user })
  end
  argv[#argv + 1] = '--database=' .. spec.database
  return argv
end

function M.command(spec, secret, mode, clients)
  assert(type(clients.mysql) == 'string', 'mysql.command: no `clients.mysql` configured')
  local env = secret and { MYSQL_PWD = secret } or nil
  return { argv = M.build_argv(spec, mode, clients.mysql), env = env }
end

--- The script a read-only run actually sends.
---
--- An open READ ONLY transaction cannot be talked out of itself: `SET SESSION TRANSACTION READ
--- WRITE` retargets only later transactions and the write still comes back ER_CANT_EXECUTE_IN_
--- READ_ONLY_TRANSACTION (1792), and `SET TRANSACTION READ WRITE` is refused outright with
--- ER_CANT_CHANGE_TX_CHARACTERISTICS (1568). Both verified live on 8.4.
---
--- It does NOT cover DDL on its own -- see `command`, which is where DDL is refused.
---
--- The bare `;` before COMMIT terminates a statement that did not terminate itself; the client
--- ignores the empty statement it makes when the caller already ended with one.
---@param statement string
---@return string
function M.read_only_script(statement)
  assert(
    type(statement) == 'string' and statement ~= '',
    'mysql.read_only_script: needs a statement'
  )
  return 'START TRANSACTION READ ONLY;\n' .. statement .. '\n;\nCOMMIT;\n'
end

local ENTITIES = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }

local function unescape(text)
  return (
    text:gsub('&(#?[%w]+);', function(name)
      if ENTITIES[name] then
        return ENTITIES[name]
      end
      local hex = name:match('^#[xX](%x+)$')
      if hex then
        return vim.fn.nr2char(tonumber(hex, 16))
      end
      local dec = name:match('^#(%d+)$')
      if dec then
        return vim.fn.nr2char(tonumber(dec, 10))
      end
      return '&' .. name .. ';'
    end)
  )
end

--- Parse one `<row>...</row>` block into ordered field names and values.
---
--- One ordered scan, not one pass per field shape: a NULL field is self-closing, and matching
--- the two shapes independently would put a mid-row NULL in the wrong position and let the
--- body pattern run past it into the following field.
local function parse_row(block)
  local names, values, pos = {}, {}, 1
  while true do
    local _, open_end = block:find('<field', pos, true)
    if not open_end then
      return names, values
    end
    local tag_end = block:find('>', open_end + 1, true)
    if not tag_end then
      return names, values
    end
    local attrs = block:sub(open_end + 1, tag_end - 1)
    local self_closing = attrs:sub(-1) == '/'
    if self_closing then
      attrs = attrs:sub(1, -2)
    end
    local is_null = self_closing or attrs:find('xsi:nil%s*=%s*"true"') ~= nil

    local value
    if self_closing then
      value, pos = protocol.NULL, tag_end + 1
    else
      local body_end = block:find('</field>', tag_end + 1, true)
      if not body_end then
        return names, values
      end
      value = is_null and protocol.NULL or unescape(block:sub(tag_end + 1, body_end - 1))
      pos = body_end + 8
    end
    names[#names + 1] = unescape(attrs:match('name="([^"]*)"') or '')
    values[#values + 1] = value
  end
end

--- The first `<resultset>` only. A statement can produce several (a CALL, some SHOW variants),
--- and their columns differ, so concatenating them would align later rows to the wrong headers.
---@return string
local function first_resultset(stdout)
  local from = stdout:find('<resultset', 1, true)
  if not from then
    return stdout
  end
  local to = stdout:find('</resultset>', from, true)
  return stdout:sub(from, to and (to - 1) or #stdout)
end

--- Decode `mysql --xml` output into a result set.
---
--- Field order within a row follows the document, and every row of a MySQL result carries the
--- same fields in the same order, so the first row defines the columns.
---@param stdout string
---@param opts { columns: string[]? }?
---@return dblens.ResultSet
function M.decode(stdout, opts)
  assert(type(stdout) == 'string', 'mysql.decode: expected string')
  opts = opts or {}
  local columns, rows, malformed = opts.columns and vim.deepcopy(opts.columns) or {}, {}, 0

  for block in first_resultset(stdout):gmatch('<row>(.-)</row>') do
    local names, values = parse_row(block)
    if #rows == 0 and #names > 0 then
      columns = names
    end
    if #columns > 0 and #values ~= #columns then
      malformed = malformed + 1
      for j = #values + 1, #columns do
        values[j] = protocol.NULL
      end
    end
    rows[#rows + 1] = values
  end

  return { columns = columns, rows = rows, malformed = malformed }
end

--- How much of a partial `--xml` stream is whole rows: everything up to the last `</row>`.
---
--- Safe because the client escapes `<` and `>` in values, so the closing tag cannot appear inside
--- one. A streamed read is one statement (`Session:stream` refuses anything else), so there is
--- only ever the one `<resultset>` and no second one's rows can be mistaken for the first's.
---@param text string
---@return integer
function M.stream_boundary(text)
  assert(type(text) == 'string', 'mysql.stream_boundary: expected a string')
  local at = text:match('^.*()</row>')
  return at and (at + 5) or 0
end

M.sql = {}

function M.sql.schemas()
  return [[SELECT schema_name AS name FROM information_schema.schemata
WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY schema_name]]
end

function M.sql.relations(schema)
  return ([[SELECT table_name AS name,
       CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS kind
FROM information_schema.tables WHERE table_schema = %s ORDER BY kind DESC, table_name]]):format(
    lit(schema)
  )
end

function M.sql.columns(relation)
  local schema, name = lit(relation.schema or ''), lit(relation.name)
  return ([[SELECT c.column_name AS name, c.column_type AS type,
       CASE WHEN c.is_nullable = 'NO' THEN 1 ELSE 0 END AS `notnull`,
       CASE WHEN c.column_key = 'PRI' THEN c.ordinal_position ELSE 0 END AS pk,
       c.column_default AS dflt,
       (SELECT group_concat(CONCAT(k.referenced_table_name, '.', k.referenced_column_name))
          FROM information_schema.key_column_usage k
         WHERE k.table_schema = c.table_schema AND k.table_name = c.table_name
           AND k.column_name = c.column_name AND k.referenced_table_name IS NOT NULL) AS fk
FROM information_schema.columns c
WHERE c.table_schema = %s AND c.table_name = %s
ORDER BY c.ordinal_position]]):format(schema, name)
end

function M.sql.indexes(relation)
  return ([[SELECT index_name AS name,
       CASE WHEN non_unique = 0 THEN 1 ELSE 0 END AS uniq,
       CASE WHEN index_name = 'PRIMARY' THEN 'pk' ELSE 'i' END AS origin,
       group_concat(column_name ORDER BY seq_in_index) AS cols
FROM information_schema.statistics WHERE table_schema = %s AND table_name = %s
GROUP BY index_name, non_unique ORDER BY index_name]]):format(
    lit(relation.schema or ''),
    lit(relation.name)
  )
end

function M.sql.constraints(relation)
  return ([[SELECT constraint_name AS name, constraint_type AS kind, constraint_type AS detail
FROM information_schema.table_constraints
WHERE table_schema = %s AND table_name = %s ORDER BY constraint_name]]):format(
    lit(relation.schema or ''),
    lit(relation.name)
  )
end

function M.sql.ddl(relation)
  return 'SHOW CREATE TABLE ' .. common.qualify(relation, dialect)
end

function M.sql.page(relation, opts)
  return common.page(relation, opts, dialect)
end

function M.sql.count(relation, where)
  return common.count(relation, where, dialect)
end

function M.sql.explain(statement, analyze)
  return (analyze and 'EXPLAIN ANALYZE ' or 'EXPLAIN ') .. statement
end

--- MySQL's EXPLAIN reports a per-step row estimate in the `rows` column.
function M.estimate(statement)
  return {
    sql = 'EXPLAIN ' .. statement,
    mode = 'records',
    parse = function(decoded)
      local index = protocol.column_index(decoded.columns, 'rows')
      local first = decoded.rows[1]
      if not index or not first then
        return nil
      end
      return tonumber(protocol.tostring(first[index]))
    end,
  }
end

function M.sql.affected()
  return 'SELECT ROW_COUNT() AS affected'
end

--- How the commit batch opens and closes. Atomicity comes from the client stopping at the first
--- error, not from these keywords.
function M.sql.batch_frame()
  return { open = 'BEGIN;', close = 'COMMIT;' }
end

--- A statement that fails unless `count_sql` yields exactly 1, re-checking a queued change's
--- guard inside the committed transaction.
---
--- MySQL has no statement-level RAISE outside a routine; a scalar subquery forced to return two
--- rows aborts with ER_SUBQUERY_NO_1_ROW, and CASE only evaluates the branch it takes.
--- Executed against MySQL 8.4: guard satisfied returns 1 and the batch continues; guard violated
--- fails with ER_SUBQUERY_NO_1_ROW at a line `exec.error_line` can read, and nothing is applied.
function M.sql.assert_one(count_sql)
  assert(type(count_sql) == 'string' and count_sql ~= '', 'mysql.assert_one: needs a count')
  return ('SELECT CASE WHEN (%s) = 1 THEN 1 ELSE (SELECT 1 UNION ALL SELECT 2) END'):format(
    count_sql
  )
end

return M
