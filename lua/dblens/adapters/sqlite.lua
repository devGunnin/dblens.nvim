--- sqlite3 adapter. The reference implementation of the adapter contract.
---
--- Requires sqlite3 >= 3.34 for `-safe`, which is what stops `.shell`, `.load`, `.import` and
--- ATTACH from reaching the host if one ever slips past the statement gate.
---
--- A read-only connection is opened `-readonly`, so the ENGINE refuses every write however the
--- statement is spelled. `PRAGMA query_only` is deliberately not used as well: it is session
--- state that a smuggled `PRAGMA query_only=OFF` can turn back off, the open mode cannot be, and
--- the only way to run a pragma ahead of stdin (`-cmd`) makes the client skip stdin entirely.
local common = require('dblens.adapters.common')
local path_mod = require('dblens.path')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local dialect = sql.dialects.sqlite

local function lit(value)
  return sql.quote_literal(value, dialect)
end

---@type dblens.Adapter
local M = {
  kind = 'sqlite',
  label = 'SQLite',
  dialect = dialect,
  --- sqlite has no schema layer we expose (attached databases are out of scope), no plan-row
  --- estimate, and no EXPLAIN ANALYZE.
  caps = {
    schemas = false,
    ddl = 'native',
    explain = true,
    explain_analyze = false,
    estimate_rows = false,
  },
  --- Required connection fields, used by the connection form and by validation.
  fields = { { name = 'path', label = 'Database file', required = true } },
}

---@param spec dblens.ConnectionSpec
---@return string? error
function M.validate(spec)
  if type(spec.path) ~= 'string' or spec.path == '' then
    return 'sqlite connection needs a `path`'
  end
  -- A path is data, never a command: expansion that cannot be done without evaluating something
  -- fails here, so nothing downstream has to defend against it. (`password_cmd` is the one field
  -- of a connection that IS a command, by the user's own declaration.)
  local _, err = path_mod.expand(spec.path)
  if err then
    return ('sqlite connection `%s`: %s'):format(spec.name or '?', err)
  end
  return nil
end

--- Human-readable target, safe to show in the UI (never carries a secret).
function M.describe(spec)
  return vim.fn.fnamemodify(spec.path, ':~')
end

--- Resolved database file for a validated spec.
---@return string
function M.file(spec)
  return path_mod.expand_validated(spec.path, 'sqlite.file')
end

---@param spec dblens.ConnectionSpec
---@param _secret string?  -- sqlite has no authentication
---@param mode 'records'|'raw'
---@param clients table<string, string>
--- `-bail` is load-bearing, not tidiness: without it the shell prints the error, skips the
--- failing statement and runs the trailing COMMIT, so a batch commits in part while the UI
--- reports that nothing landed. `-safe` refuses `.shell`/`.load`/`.import`/ATTACH, and
--- `-readonly` is what actually enforces a read-only connection.
function M.command(spec, _secret, mode, clients)
  local argv = { clients.sqlite, '-batch', '-bail', '-safe' }
  if spec.read_only == true then
    argv[#argv + 1] = '-readonly'
  end
  if mode == 'records' then
    vim.list_extend(argv, { '-ascii', '-header', '-nullvalue', protocol.NULL_SENTINEL })
  end
  argv[#argv + 1] = M.file(spec)
  return { argv = argv, env = nil }
end

--- sqlite needs no transaction wrap: `-readonly` is the open mode of the file handle, so there
--- is no session state for a statement to flip and nothing a wrapper could add.
---@param statement string
---@return string
function M.read_only_script(statement)
  assert(
    type(statement) == 'string' and statement ~= '',
    'sqlite.read_only_script: needs a statement'
  )
  return statement
end

M.decode = protocol.decode

M.sql = {}

--- sqlite exposes one implicit schema, so the tree skips the schema level entirely.
function M.sql.schemas()
  return nil
end

function M.sql.relations(_schema)
  return 'SELECT name AS name, type AS kind FROM sqlite_schema '
    .. "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
    .. 'ORDER BY type DESC, name'
end

function M.sql.columns(relation)
  local name = lit(relation.name)
  -- `notnull` is a SQLite keyword, so the alias must stay quoted.
  return ([[SELECT ti.name AS name, ti.type AS type, ti."notnull" AS "notnull", ti.pk AS pk,
       ti.dflt_value AS dflt,
       (SELECT group_concat(fk."table" || '.' || COALESCE(fk."to", ''), ', ')
          FROM pragma_foreign_key_list(%s) fk WHERE fk."from" = ti.name) AS fk
FROM pragma_table_info(%s) ti ORDER BY ti.cid]]):format(name, name)
end

function M.sql.indexes(relation)
  return ([[SELECT il.name AS name, il."unique" AS uniq, il.origin AS origin,
       (SELECT group_concat(ii.name) FROM pragma_index_info(il.name) ii) AS cols
FROM pragma_index_list(%s) il ORDER BY il.name]]):format(lit(relation.name))
end

--- sqlite has no constraint catalog; the tree derives constraints from columns and indexes.
function M.sql.constraints(_relation)
  return nil
end

function M.sql.ddl(relation)
  return ('SELECT sql AS ddl FROM sqlite_schema WHERE name = %s AND sql IS NOT NULL'):format(
    lit(relation.name)
  )
end

function M.sql.page(relation, opts)
  return common.page(relation, opts, dialect)
end

function M.sql.count(relation, where)
  return common.count(relation, where, dialect)
end

function M.sql.explain(statement, analyze)
  assert(not analyze, 'sqlite: EXPLAIN ANALYZE is unsupported; caps.explain_analyze is false')
  return 'EXPLAIN QUERY PLAN ' .. statement
end

--- Rows touched by the statement that just ran, in the same client invocation.
function M.sql.affected()
  return 'SELECT changes() AS affected'
end

--- A statement that fails unless `count_sql` yields exactly 1, so a queued change is re-guarded
--- inside the committed transaction rather than only at queue time.
---
--- sqlite has no RAISE outside a trigger and returns NULL for `1/0`; `json()` over invalid text
--- is the portable way to make the shell abort, and with `-bail` that rolls the batch back.
function M.sql.assert_one(count_sql)
  assert(type(count_sql) == 'string' and count_sql ~= '', 'sqlite.assert_one: needs a count')
  return ("SELECT CASE WHEN (%s) = 1 THEN 1 ELSE json('dblens row guard failed') END"):format(
    count_sql
  )
end

return M
