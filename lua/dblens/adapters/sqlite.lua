--- sqlite3 adapter. The reference implementation of the adapter contract.
local common = require('dblens.adapters.common')
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
  caps = { schemas = false, ddl = 'native', explain = true, explain_analyze = false, estimate_rows = false },
  --- Required connection fields, used by the connection form and by validation.
  fields = { { name = 'path', label = 'Database file', required = true } },
}

---@param spec dblens.ConnectionSpec
---@return string? error
function M.validate(spec)
  if type(spec.path) ~= 'string' or spec.path == '' then
    return 'sqlite connection needs a `path`'
  end
  return nil
end

--- Human-readable target, safe to show in the UI (never carries a secret).
function M.describe(spec)
  return vim.fn.fnamemodify(spec.path, ':~')
end

---@param spec dblens.ConnectionSpec
---@param _secret string?  -- sqlite has no authentication
---@param mode 'records'|'raw'
---@param clients table<string, string>
function M.command(spec, _secret, mode, clients)
  local argv = { clients.sqlite, '-batch' }
  if mode == 'records' then
    vim.list_extend(argv, { '-ascii', '-header', '-nullvalue', protocol.NULL_SENTINEL })
  end
  argv[#argv + 1] = vim.fn.expand(spec.path)
  return { argv = argv, env = nil }
end

M.decode = protocol.decode

M.sql = {}

--- sqlite exposes one implicit schema, so the tree skips the schema level entirely.
function M.sql.schemas()
  return nil
end

function M.sql.relations(_schema)
  return "SELECT name AS name, type AS kind FROM sqlite_schema "
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
  return ('SELECT sql AS ddl FROM sqlite_schema WHERE name = %s AND sql IS NOT NULL'):format(lit(relation.name))
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

return M
