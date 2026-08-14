--- DuckDB adapter, driven through the `duckdb` CLI.
---
--- DuckDB's shell descends from sqlite3's, so this adapter is shaped like the sqlite one: the
--- database is a local FILE, and a read-only connection is the file's OPEN MODE rather than a
--- transaction. Verified live on DuckDB 1.5.5 through the argv this file builds:
---  * `-readonly` refuses INSERT/DROP with "Cannot execute statement of type ... on database ...
---    which is attached in read-only mode", and reads still return their rows;
---  * `-readonly` ALONE is not enough. `COPY (SELECT 1) TO '/tmp/x.csv'` under `-readonly` WROTE
---    the file: read-only covers the database, not the filesystem. `-safe` is what refuses that
---    ("file system operations are disabled by configuration"), and both are needed;
---  * `-ascii` does NOT set the separators sqlite3's does -- it emits `\n` for both the field and
---    the record separator, which is unusable. `-list` with explicit `-separator`/`-newline` is
---    what produces the record protocol.
---
--- `-safe` is applied only while LOCKED, on purpose. It disables ALL filesystem access, so
--- applying it always would break `read_csv`/`read_parquet`, which is most of what DuckDB is for.
--- That matches how every other adapter treats a filesystem reach: refused while locked, allowed
--- once the user has explicitly unlocked.
local common = require('dblens.adapters.common')
local path_mod = require('dblens.path')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local dialect = sql.dialects.duckdb

local function lit(value)
  return sql.quote_literal(value, dialect)
end

---@type dblens.Adapter
local M = {
  kind = 'duckdb',
  label = 'DuckDB',
  dialect = dialect,
  --- DuckDB has real schemas and a native DDL string in `duckdb_tables()`. It has no per-step row
  --- estimate we can read back, so a destructive statement gets no blast-radius preview.
  caps = {
    schemas = true,
    ddl = 'native',
    explain = true,
    explain_analyze = true,
    estimate_rows = false,
  },
  read_only_enforcement = {
    mechanism = 'file-open',
    strength = 'strong',
    summary = 'the database file is opened `-readonly` and the client runs `-safe`, so the '
      .. 'engine refuses every write and every filesystem reach',
  },
  fields = { { name = 'path', label = 'Database file', required = true } },
}

---@param spec dblens.ConnectionSpec
---@return string? error
function M.validate(spec)
  if type(spec.path) ~= 'string' or spec.path == '' then
    return 'duckdb connection needs a `path`'
  end
  -- Same rule as sqlite: a path is data, and expansion that would evaluate something fails here.
  local _, err = path_mod.expand(spec.path)
  if err then
    return ('duckdb connection `%s`: %s'):format(spec.name or '?', err)
  end
  return nil
end

function M.describe(spec)
  return vim.fn.fnamemodify(spec.path, ':~')
end

--- Resolved database file for a validated spec.
---@return string
function M.file(spec)
  return path_mod.expand_validated(spec.path, 'duckdb.file')
end

---@param spec dblens.ConnectionSpec
---@param _secret string?  -- duckdb has no authentication
---@param mode 'records'|'raw'
---@param clients table<string, string>
function M.command(spec, _secret, mode, clients)
  assert(type(clients.duckdb) == 'string', 'duckdb.command: no `clients.duckdb` configured')
  local argv = { clients.duckdb, '-batch', '-bail' }
  if spec.read_only == true then
    vim.list_extend(argv, { '-readonly', '-safe' })
  end
  if mode == 'records' then
    vim.list_extend(argv, {
      '-list',
      '-header',
      '-separator',
      protocol.FIELD_SEP,
      '-newline',
      protocol.RECORD_SEP,
      '-nullvalue',
      protocol.NULL_SENTINEL,
    })
  end
  argv[#argv + 1] = M.file(spec)
  return { argv = argv, env = nil }
end

--- No wrap: `-readonly` is the open mode of the database file, so there is no session state for a
--- statement to flip and nothing a transaction could add.
---@param statement string
---@return string
function M.read_only_script(statement)
  assert(
    type(statement) == 'string' and statement ~= '',
    'duckdb.read_only_script: needs a statement'
  )
  return statement
end

M.decode = protocol.decode

M.sql = {}

--- One row per schema of the CURRENT database. DuckDB can have several databases attached and
--- `information_schema.schemata` lists a `main` per catalog, so the rows must be narrowed to this
--- one or the tree shows the same schema several times.
function M.sql.schemas()
  return [[SELECT DISTINCT schema_name AS name FROM duckdb_schemas()
WHERE database_name = current_database()
  AND schema_name NOT IN ('information_schema','pg_catalog') ORDER BY name]]
end

function M.sql.relations(schema)
  return ([[SELECT table_name AS name,
       CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS kind
FROM information_schema.tables WHERE table_schema = %s ORDER BY kind DESC, table_name]]):format(
    lit(schema)
  )
end

--- Column list with its primary-key position and foreign-key target.
---
--- `information_schema` carries no key information in DuckDB, so both come from
--- `duckdb_constraints()`, whose `constraint_column_names` is a LIST -- hence `list_position`
--- for the key ordinal and `list_contains` for membership.
function M.sql.columns(relation)
  local schema, name = lit(relation.schema or 'main'), lit(relation.name)
  return ([[SELECT c.column_name AS name, c.data_type AS type,
       CASE WHEN c.is_nullable = 'NO' THEN 1 ELSE 0 END AS "notnull",
       COALESCE((SELECT list_position(k.constraint_column_names, c.column_name)
                   FROM duckdb_constraints() k
                  WHERE k.schema_name = c.table_schema AND k.table_name = c.table_name
                    AND k.constraint_type = 'PRIMARY KEY'), 0) AS pk,
       c.column_default AS dflt,
       (SELECT string_agg(f.constraint_text, ', ')
          FROM duckdb_constraints() f
         WHERE f.schema_name = c.table_schema AND f.table_name = c.table_name
           AND f.constraint_type = 'FOREIGN KEY'
           AND list_contains(f.constraint_column_names, c.column_name)) AS fk
FROM information_schema.columns c
WHERE c.table_schema = %s AND c.table_name = %s
ORDER BY c.ordinal_position]]):format(schema, name)
end

function M.sql.indexes(relation)
  return ([[SELECT index_name AS name,
       CASE WHEN is_unique THEN 1 ELSE 0 END AS uniq, 'i' AS origin, sql AS cols
FROM duckdb_indexes() WHERE schema_name = %s AND table_name = %s ORDER BY index_name]]):format(
    lit(relation.schema or 'main'),
    lit(relation.name)
  )
end

function M.sql.constraints(relation)
  return ([[SELECT constraint_type AS name, constraint_type AS kind, constraint_text AS detail
FROM duckdb_constraints() WHERE schema_name = %s AND table_name = %s
ORDER BY constraint_type, constraint_text]]):format(
    lit(relation.schema or 'main'),
    lit(relation.name)
  )
end

function M.sql.ddl(relation)
  local schema, name = lit(relation.schema or 'main'), lit(relation.name)
  return ([[SELECT sql AS ddl FROM duckdb_tables()
WHERE schema_name = %s AND table_name = %s
UNION ALL
SELECT sql AS ddl FROM duckdb_views() WHERE schema_name = %s AND view_name = %s]]):format(
    schema,
    name,
    schema,
    name
  )
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

--- DuckDB has no `changes()`, and a DML statement prints nothing at all through the CLI (verified
--- on 1.5.5), so an affected-row count cannot be read back. The UI reports the change as applied
--- without a count, the same way postgres does.
function M.sql.affected()
  return nil
end

--- A statement that fails unless `count_sql` yields exactly 1, re-checking a queued change's guard
--- inside the committed transaction. `error()` raises, and with `-bail` that aborts the batch.
function M.sql.assert_one(count_sql)
  assert(type(count_sql) == 'string' and count_sql ~= '', 'duckdb.assert_one: needs a count')
  return ("SELECT CASE WHEN (%s) = 1 THEN 1 ELSE error('dblens row guard failed') END"):format(
    count_sql
  )
end

--- How the commit batch opens and closes. Atomicity comes from `-bail`: verified that a batch
--- whose second statement fails leaves the first one rolled back.
function M.sql.batch_frame()
  return { open = 'BEGIN;', close = 'COMMIT;' }
end

return M
