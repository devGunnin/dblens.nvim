--- Microsoft SQL Server adapter, driven through `sqlcmd`.
---
--- READ THIS BEFORE TRUSTING A LOCKED mssql CONNECTION. It is the ONE engine dblens supports
--- whose LOCKED mode is not enforced by the engine, and it must never be presented as if it were.
--- Its lock is BEST-EFFORT (beta) and dblens does not claim it is complete: the classifier is a
--- blocklist of verbs, so an unlisted state-changing verb is a write rather than a refusal. For a
--- hard read-only boundary on SQL Server, connect as a read-only SQL login (recipe at the bottom
--- of this header). Everything below is what best-effort buys, and where it stops.
---
--- Every other adapter can point at something the SERVER does: sqlite and duckdb open the file
--- read-only, postgres/mysql/mariadb send the run inside a read-only transaction the server
--- refuses writes in. SQL Server has NEITHER. There is no read-only transaction (`BEGIN
--- TRANSACTION` has no READ ONLY mode) and no read-only connection mode: `-K ReadOnly` only
--- routes to a readable secondary in an availability group, and on a standalone server an INSERT
--- sent under it LANDS -- verified live on SQL Server 2022.
---
--- So LOCKED here rests on dblens's own classifier, plus two client-side refusals, and a bug in
--- any of them is a WRITE rather than a prompt:
---  1. `sql.classify` must prove the statement is a read; anything else is refused as a write.
---  2. T-SQL ENDS A STATEMENT AT WHITESPACE. `SELECT 1 DROP TABLE t` is two statements with no
---     `;` in it -- verified live, the table was dropped. So `single_statement_problem`, which is
---     a scan for `;`, proves nothing here. The `mssql` dialect sets
---     `statement_separator_optional`, so on THIS dialect the classifier treats a write verb
---     anywhere but the head as opening a statement -- including one followed by `(`, because
---     `EXEC('...')` is T-SQL's dynamic-SQL statement, not a function call. Exempting it as a call
---     is what let `SELECT 1 EXEC('COMMIT TRANSACTION DROP TABLE t')` through as a READ on a
---     locked connection, verified live on 2022. The price of not exempting it: an ordinary
---     `SELECT REPLACE(a,'x','y')` is refused HERE and nowhere else, and so is an unquoted column
---     named after a write verb. Quote the name and it is an identifier again.
---  3. `GO` is a sqlcmd BATCH separator, so what follows it runs as its OWN batch -- a second
---     statement no framing rule sees. Verified live that `SELECT 1 / GO / DROP TABLE t` dropped
---     the table, and that `sqlcmd -X` does not stop it. `client_meta_problem` refuses `GO` and
---     the `:` commands for this dialect.
---  4. A string literal can BE code here (`EXEC('...')`), so the `mssql` dialect also sets
---     `string_is_code` and `side_channel_problem` scans inside quoted strings on this engine.
---
--- WHAT IT STILL DOES NOT COVER: anything the classifier does not recognise as a write. It is a
--- lexer, not SQL Server's parser, and on this engine there is no second layer that refuses.
--- The known administrative verbs are listed (`TSQL_WRITE_VERBS` in `sql.lua`: DBCC, BACKUP,
--- RESTORE, DENY, CHECKPOINT, RECONFIGURE, KILL, SHUTDOWN, WRITETEXT, UPDATETEXT, DISABLE,
--- ENABLE, RECEIVE) because `SELECT 1 DBCC TRACEON(3999,-1)` classified as a READ and flipped a
--- global trace flag on a LOCKED connection -- verified live on 2022, and the wrap below did not undo
--- it because DBCC is not transactional. That list is DEFENCE IN DEPTH, not a completeness
--- claim: T-SQL has more verbs than dblens knows, and the next unlisted one behaves the same way.
---
--- `read_only_script` additionally wraps a locked run in a transaction that is ROLLED BACK. That
--- is defence in depth, not the guarantee, and the limit was measured rather than assumed:
---  * a write that gets past the classifier is undone -- INSERT and DROP TABLE inside the wrap
---    both left the database unchanged, because SQL Server DDL is transactional;
---  * a `GO` alone does not escape it either: the transaction survives the batch boundary on the
---    same connection, so the trailing ROLLBACK still reaches the write;
---  * but anything that COMMITS the wrap away escapes it, and what follows runs in autocommit --
---    `... GO ... INSERT ... COMMIT TRANSACTION`, and `EXEC('COMMIT TRANSACTION INSERT ...')`
---    with no `GO` at all. Both are refused by the classifier now; the wrap alone never stopped
---    them. The batch THROWs when it finds the transaction gone, so such a run is reported as a
---    failure rather than a success.
---
--- THE HARD BOUNDARY IS A READ-ONLY SQL LOGIN, and it is the one dblens recommends here:
---
---     CREATE LOGIN dblens_ro WITH PASSWORD = '...';
---     CREATE USER dblens_ro FOR LOGIN dblens_ro;
---     ALTER ROLE db_datareader ADD MEMBER dblens_ro;   -- or: GRANT SELECT TO dblens_ro;
---     DENY EXECUTE TO dblens_ro;
---
--- The server then refuses the write, which is what every other engine gives for free. See README
--- and `:h dblens-safety-mssql`.
local common = require('dblens.adapters.common')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local dialect = sql.dialects.mssql

local function lit(value)
  return sql.quote_literal(value, dialect)
end

---@type dblens.Adapter
local M = {
  kind = 'mssql',
  label = 'SQL Server',
  dialect = dialect,
  --- No EXPLAIN: a SQL Server plan needs `SET SHOWPLAN_ALL ON` as its own batch, and dblens sends
  --- one statement per client invocation. No row estimate for the same reason.
  caps = {
    schemas = true,
    ddl = 'reconstructed',
    explain = false,
    explain_analyze = false,
    estimate_rows = false,
    ilike = false,
  },
  read_only_enforcement = {
    mechanism = 'classifier',
    strength = 'best-effort',
    summary = 'BETA. SQL Server has no read-only transaction or connection mode, so LOCKED is '
      .. "dblens's own verb classifier plus a rolled-back transaction. It is a blocklist, so it "
      .. 'cannot guarantee every administrative or DBCC statement is refused -- connect as a '
      .. 'read-only SQL login (db_datareader, DENY EXECUTE) for a boundary the server enforces',
  },
  fields = {
    { name = 'host', label = 'Host', default = 'localhost' },
    { name = 'port', label = 'Port', default = 1433 },
    { name = 'user', label = 'User' },
    { name = 'database', label = 'Database', required = true },
    --- ODBC Driver 18 encrypts by default and then verifies the certificate, which a dev server's
    --- self-signed one fails. Set this only when you know the server is the one you meant.
    { name = 'trust_server_certificate', label = 'Trust the server certificate (y/n)' },
  },
}

function M.validate(spec)
  if type(spec.database) ~= 'string' or spec.database == '' then
    return 'mssql connection needs a `database`'
  end
  if spec.port ~= nil and type(spec.port) ~= 'number' then
    return 'mssql `port` must be a number'
  end
  -- `-S` takes a whole connection string, so a stored spec could otherwise redirect the
  -- connection (and the password) to a host the UI never shows. Same rule as postgres's database.
  if spec.host ~= nil and (type(spec.host) ~= 'string' or spec.host:find('[%s,;:\\]')) then
    return 'mssql `host` must be a bare host name, not a connection string'
  end
  if spec.database:find('[%s;=]') then
    return 'mssql `database` must be a bare database name, not a connection string'
  end
  return common.argv_field_problem(spec, 'mssql', { 'host', 'user', 'database' })
end

function M.describe(spec)
  return ('%s@%s:%s/%s'):format(
    spec.user or '$USER',
    spec.host or 'localhost',
    spec.port or 1433,
    spec.database
  )
end

--- Truthy spellings a hand-edited connections file may carry for a boolean field.
local function is_yes(value)
  return value == true or value == 'y' or value == 'yes' or value == 'true'
end

--- Build the sqlcmd invocation. The password never touches argv: sqlcmd reads SQLCMDPASSWORD.
---
--- Every flag here was chosen against live behaviour on SQL Server 2022, and four are
--- load-bearing rather than cosmetic:
---  * `-b` -- without it sqlcmd exits 0 on a failed statement, so a failed batch read as success.
---  * `-r1` -- without it sqlcmd writes its `Msg ...` errors to STDOUT, where the decoder would
---    have parsed them as result rows.
---  * `-k1` -- removes control characters from VALUES. That is what keeps the record framing
---    honest: without it a value holding 0x1F split the row and one holding a newline split the
---    record, the same corruption psql's unaligned output caused.
---  * `-X1` -- refuses sqlcmd's `:`-commands and `!!`. Verified: without it, `:!! touch ...` ran
---    a shell command on the machine running the client. It does NOT cover `GO`; the gate does.
--- `-I` sets QUOTED_IDENTIFIER ON, which is what makes the `"name"` quoting dblens emits legal.
function M.command(spec, secret, mode, clients)
  assert(type(clients.mssql) == 'string', 'mssql.command: no `clients.mssql` configured')
  local argv = { clients.mssql, '-b', '-r1', '-X1', '-I', '-k1', '-W', '-l', '10' }
  if mode == 'records' then
    vim.list_extend(argv, { '-s', protocol.FIELD_SEP })
  else
    vim.list_extend(argv, { '-h', '-1' })
  end
  -- NOT ENFORCEMENT. `-K ReadOnly` declares ApplicationIntent, which only routes to a readable
  -- secondary in an availability group; verified live that an INSERT sent under it on a
  -- standalone server LANDS. It is here because it is the truthful thing to declare, and because
  -- against an AG it does route away from the primary. The refusal is the gate's.
  if spec.read_only == true then
    vim.list_extend(argv, { '-K', 'ReadOnly' })
  end
  if is_yes(spec.trust_server_certificate) then
    argv[#argv + 1] = '-C'
  end
  vim.list_extend(argv, { '-S', ('tcp:%s,%d'):format(spec.host or 'localhost', spec.port or 1433) })
  if spec.user then
    vim.list_extend(argv, { '-U', spec.user })
  end
  vim.list_extend(argv, { '-d', spec.database })

  local env = secret and { SQLCMDPASSWORD = secret } or nil
  return { argv = argv, env = env }
end

--- The script a locked run sends: the statement inside a transaction that is rolled back.
---
--- This is NOT what makes the connection read-only -- the gate is (see the file header). It is the
--- net under it: `SET XACT_ABORT ON` makes any error abort and roll back, and the explicit
--- ROLLBACK undoes anything a classifier miss managed to write. Verified live that both an INSERT
--- and a DROP TABLE inside this wrap left the database unchanged, and that a SELECT still returns
--- its rows.
---
--- The `THROW` is the honesty clause. A statement that commits the wrap away leaves `@@TRANCOUNT`
--- at 0, and the trailing ROLLBACK is then a no-op the client still exits 0 on -- dblens would
--- report success for a run whose net was cut. Failing the batch instead makes that visible.
---@param statement string
---@return string
function M.read_only_script(statement)
  assert(
    type(statement) == 'string' and statement ~= '',
    'mssql.read_only_script: needs a statement'
  )
  return 'SET XACT_ABORT ON;\nBEGIN TRANSACTION;\n'
    .. statement
    .. "\n;\nIF @@TRANCOUNT = 0 THROW 50002, 'dblens: the read-only transaction was committed "
    .. "away by this statement', 1;\nIF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;\n"
end

--- sqlcmd's trailing summary line, which is a message rather than a row.
local ROWS_AFFECTED = '^%(%d+ rows? affected%)$'

--- Whether a line is the dashed rule sqlcmd prints under the header.
local function is_underline(line)
  local seen = false
  for field in
    (line .. protocol.FIELD_SEP):gmatch('([^' .. protocol.FIELD_SEP .. ']*)' .. protocol.FIELD_SEP)
  do
    if not field:match('^%-+$') then
      return false
    end
    seen = true
  end
  return seen
end

local function split_lines(text)
  local out = {}
  for line in (text:gsub('\r\n', '\n') .. '\n'):gmatch('([^\n]*)\n') do
    out[#out + 1] = line
  end
  -- The trailing newline every client emits makes one empty line that is not a record.
  if out[#out] == '' then
    table.remove(out)
  end
  return out
end

local function split_fields(line)
  local fields, from = {}, 1
  while true do
    local at = line:find(protocol.FIELD_SEP, from, true)
    local raw = at and line:sub(from, at - 1) or line:sub(from)
    fields[#fields + 1] = raw == 'NULL' and protocol.NULL or raw
    if not at then
      return fields
    end
    from = at + 1
  end
end

--- Whether the blank line at `index` ends the result set, rather than being a row whose single
--- column is empty. sqlcmd always follows the last row with a blank line and the row count, so a
--- blank followed by that pair is the terminator and a blank followed by more data is a row.
local function ends_result(lines, index)
  for i = index + 1, #lines do
    if lines[i] ~= '' then
      return lines[i]:match(ROWS_AFFECTED) ~= nil
    end
  end
  return true
end

--- Whether the summary line at `index` is sqlcmd's terminator rather than a row whose single
--- column happens to READ like one.
---
--- Position decides it, not content: the real summary is the last thing in the output, so a
--- `(3 rows affected)` with more data after it is a value from a message or audit column. Matching
--- on content alone truncated the result set there and reported `malformed = 0` -- a silent wrong
--- answer, which is the worst failure a data viewer has.
local function is_trailing_summary(lines, index)
  if not lines[index]:match(ROWS_AFFECTED) then
    return false
  end
  for i = index + 1, #lines do
    if lines[i] ~= '' then
      return false
    end
  end
  return true
end

--- Decode sqlcmd's text output into a result set.
---
--- The shape is fixed: header line, dashed rule, rows, blank line, `(N rows affected)`. Only the
--- FIRST result set is decoded, for the reason the mysql adapter gives -- a second one's columns
--- differ, so concatenating would align its rows to the wrong headers.
---
--- TWO LIMITATIONS OF THIS PROTOCOL, both inherent to sqlcmd's text output and neither hidden:
---  * SQL NULL prints as the four characters `NULL` and is INDISTINGUISHABLE from the string
---    'NULL'. sqlcmd has no null-marker option (mysql has `--xml`, psql has `-P null=`); this is
---    the one engine where a cell can be misreported.
---  * `-k1` replaces control characters INSIDE values with a space, so a value holding a newline
---    or a tab is flattened, and `-W` trims trailing spaces off every field. Both are deliberate:
---    `-k1` is what stops such a value from splitting the record, and without `-W` every field
---    arrives padded to the column's display width. A flattened cell beats a corrupted grid.
---@param stdout string
---@param opts { columns: string[]? }?
---@return dblens.ResultSet
function M.decode(stdout, opts)
  assert(type(stdout) == 'string', 'mssql.decode: expected string')
  opts = opts or {}
  local lines = split_lines(stdout)
  local columns, rows, malformed = opts.columns and vim.deepcopy(opts.columns) or {}, {}, 0

  local index = 1
  while lines[index] == '' do
    index = index + 1
  end
  if not lines[index] then
    return { columns = columns, rows = rows, malformed = 0 }
  end
  columns = split_fields(lines[index])
  for i, name in ipairs(columns) do
    columns[i] = name == protocol.NULL and '' or name
  end
  index = index + 1
  if lines[index] and is_underline(lines[index]) then
    index = index + 1
  end

  while lines[index] do
    local line = lines[index]
    if (line == '' and ends_result(lines, index)) or is_trailing_summary(lines, index) then
      break
    end
    local fields = split_fields(line)
    if #columns > 0 and #fields ~= #columns then
      malformed = malformed + 1
      for j = #fields + 1, #columns do
        fields[j] = protocol.NULL
      end
    end
    rows[#rows + 1] = fields
    index = index + 1
  end

  return { columns = columns, rows = rows, malformed = malformed }
end

M.sql = {}

--- User schemas only: the fixed database roles are schemas too, and listing them would bury the
--- one or two a user actually has.
function M.sql.schemas()
  return [[SELECT name AS name FROM sys.schemas
WHERE name NOT IN ('sys','INFORMATION_SCHEMA','guest') AND name NOT LIKE 'db[_]%'
ORDER BY name]]
end

function M.sql.relations(schema)
  return ([[SELECT table_name AS name,
       CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS kind
FROM information_schema.tables WHERE table_schema = %s ORDER BY kind DESC, table_name]]):format(
    lit(schema)
  )
end

--- `information_schema.constraint_column_usage` reports the REFERENCING column for a SQL Server
--- foreign key, not the referenced one, so the target comes from `sys.foreign_key_columns`.
function M.sql.columns(relation)
  local schema, name = lit(relation.schema or 'dbo'), lit(relation.name)
  local qualified = lit((relation.schema or 'dbo') .. '.' .. relation.name)
  return ([[SELECT c.column_name AS name, c.data_type AS type,
       CASE WHEN c.is_nullable = 'NO' THEN 1 ELSE 0 END AS "notnull",
       COALESCE(pk.ordinal_position, 0) AS pk,
       c.column_default AS dflt,
       (SELECT TOP 1 rt.name + '.' + rc.name
          FROM sys.foreign_key_columns fkc
          JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id
                             AND pc.column_id = fkc.parent_column_id
          JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id
                             AND rc.column_id = fkc.referenced_column_id
          JOIN sys.objects rt ON rt.object_id = fkc.referenced_object_id
         WHERE fkc.parent_object_id = OBJECT_ID(%s) AND pc.name = c.column_name) AS fk
FROM information_schema.columns c
LEFT JOIN (
  SELECT kcu.column_name, kcu.ordinal_position
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
  WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = %s AND tc.table_name = %s
) pk ON pk.column_name = c.column_name
WHERE c.table_schema = %s AND c.table_name = %s
ORDER BY c.ordinal_position]]):format(qualified, schema, name, schema, name)
end

function M.sql.indexes(relation)
  return ([[SELECT i.name AS name,
       CASE WHEN i.is_unique = 1 THEN 1 ELSE 0 END AS uniq,
       CASE WHEN i.is_primary_key = 1 THEN 'pk' ELSE 'i' END AS origin,
       STUFF((SELECT ', ' + col.name FROM sys.index_columns ic
                JOIN sys.columns col ON col.object_id = ic.object_id
                                    AND col.column_id = ic.column_id
               WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
               ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, '') AS cols
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = %s AND o.name = %s AND i.name IS NOT NULL ORDER BY i.name]]):format(
    lit(relation.schema or 'dbo'),
    lit(relation.name)
  )
end

function M.sql.constraints(relation)
  return ([[SELECT constraint_name AS name, constraint_type AS kind, constraint_type AS detail
FROM information_schema.table_constraints
WHERE table_schema = %s AND table_name = %s ORDER BY constraint_name]]):format(
    lit(relation.schema or 'dbo'),
    lit(relation.name)
  )
end

--- No native DDL statement; `dblens.ddl` reconstructs it from the catalog, as for postgres.
function M.sql.ddl(_relation)
  return nil
end

--- T-SQL has no `LIMIT`: paging is `OFFSET n ROWS FETCH NEXT m ROWS ONLY`, and that REQUIRES an
--- ORDER BY, so an unsorted page is ordered by a constant.
function M.sql.page(relation, opts)
  assert(type(opts.limit) == 'number' and opts.limit > 0, 'mssql.page: limit must be positive')
  assert(
    type(opts.offset) == 'number' and opts.offset >= 0,
    'mssql.page: offset must not be negative'
  )
  local keys = common.order_keys(opts.order_by, opts.tiebreak, dialect)
  local order = #keys > 0 and table.concat(keys, ', ') or '(SELECT NULL)'
  local where = ''
  if opts.where and vim.trim(opts.where) ~= '' then
    assert(
      common.check_predicate(opts.where, dialect) == nil,
      'mssql.page: unsafe predicate reached SQL generation'
    )
    where = ' WHERE ' .. vim.trim(opts.where)
  end
  return ('SELECT * FROM %s%s ORDER BY %s OFFSET %d ROWS FETCH NEXT %d ROWS ONLY'):format(
    common.qualify(relation, dialect),
    where,
    order,
    opts.offset,
    opts.limit
  )
end

function M.sql.count(relation, where)
  return common.count(relation, where, dialect)
end

--- caps.explain is false, so nothing should reach this; it fails loudly rather than sending a
--- statement SQL Server cannot run in a one-statement batch.
function M.sql.explain(_statement, _analyze)
  error('mssql: EXPLAIN needs its own batch (SET SHOWPLAN_ALL ON); caps.explain is false', 0)
end

function M.sql.affected()
  return 'SELECT @@ROWCOUNT AS affected'
end

--- A statement that fails unless `count_sql` yields exactly 1. THROW aborts the batch, and with
--- `SET XACT_ABORT ON` in the batch frame the transaction rolls back.
function M.sql.assert_one(count_sql)
  assert(type(count_sql) == 'string' and count_sql ~= '', 'mssql.assert_one: needs a count')
  return ("IF (%s) <> 1 THROW 50000, 'dblens row guard failed', 1"):format(count_sql)
end

--- `BEGIN;` is a block, not a transaction, in T-SQL. `SET XACT_ABORT ON` is what makes the batch
--- atomic: verified live that a batch whose second INSERT fails leaves the first one rolled back
--- and sqlcmd exits nonzero.
function M.sql.batch_frame()
  return { open = 'SET XACT_ABORT ON;\nBEGIN TRANSACTION;', close = 'COMMIT TRANSACTION;' }
end

return M
