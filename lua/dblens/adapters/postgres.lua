--- PostgreSQL adapter, driven through `psql`.
---
--- UNTESTED LIVE: developed against psql's documented flags and catalog views; no server was
--- reachable during development. The record framing and every statement builder are unit-tested.
local common = require('dblens.adapters.common')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local dialect = sql.dialects.postgres

local function lit(value)
  return sql.quote_literal(value, dialect)
end

---@type dblens.Adapter
local M = {
  kind = 'postgres',
  label = 'PostgreSQL',
  dialect = dialect,
  --- No native DDL statement, so DDL is reconstructed from the catalog.
  caps = { schemas = true, ddl = 'reconstructed', explain = true, explain_analyze = true, estimate_rows = true },
  fields = {
    { name = 'host', label = 'Host', default = 'localhost' },
    { name = 'port', label = 'Port', default = 5432 },
    { name = 'user', label = 'User' },
    { name = 'database', label = 'Database', required = true },
  },
}

function M.validate(spec)
  if type(spec.database) ~= 'string' or spec.database == '' then
    return 'postgres connection needs a `database`'
  end
  if spec.port ~= nil and type(spec.port) ~= 'number' then
    return 'postgres `port` must be a number'
  end
  return nil
end

function M.describe(spec)
  return ('%s@%s:%s/%s'):format(spec.user or '$USER', spec.host or 'localhost', spec.port or 5432, spec.database)
end

--- Build the psql invocation. The password never touches argv: psql reads PGPASSWORD.
function M.command(spec, secret, mode, clients)
  local argv = { clients.postgres, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-P', 'pager=off', '-P', 'footer=off' }
  if mode == 'records' then
    vim.list_extend(argv, {
      '-A',
      '-F', protocol.FIELD_SEP,
      '-R', protocol.RECORD_SEP,
      '-P', 'null=' .. protocol.NULL_SENTINEL,
    })
  else
    vim.list_extend(argv, { '-A', '-t' })
  end
  if spec.host then
    vim.list_extend(argv, { '-h', spec.host })
  end
  if spec.port then
    vim.list_extend(argv, { '-p', tostring(spec.port) })
  end
  if spec.user then
    vim.list_extend(argv, { '-U', spec.user })
  end
  vim.list_extend(argv, { '-d', spec.database })

  local env = { PGCONNECT_TIMEOUT = '10' }
  if secret then
    env.PGPASSWORD = secret
  end
  if spec.sslmode then
    env.PGSSLMODE = spec.sslmode
  end
  return { argv = argv, env = env }
end

M.decode = protocol.decode

M.sql = {}

function M.sql.schemas()
  return [[SELECT nspname AS name FROM pg_namespace
WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema' ORDER BY nspname]]
end

function M.sql.relations(schema)
  return ([[SELECT table_name AS name,
       CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS kind
FROM information_schema.tables WHERE table_schema = %s ORDER BY kind DESC, table_name]]):format(lit(schema))
end

function M.sql.columns(relation)
  local schema, name = lit(relation.schema or 'public'), lit(relation.name)
  return ([[SELECT c.column_name AS name, c.data_type AS type,
       CASE WHEN c.is_nullable = 'NO' THEN 1 ELSE 0 END AS "notnull",
       COALESCE(pk.ordinal_position, 0) AS pk,
       c.column_default AS dflt, fk.ref AS fk
FROM information_schema.columns c
LEFT JOIN (
  SELECT kcu.column_name, kcu.ordinal_position
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
  WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = %s AND tc.table_name = %s
) pk ON pk.column_name = c.column_name
LEFT JOIN (
  SELECT kcu.column_name, ccu.table_name || '.' || ccu.column_name AS ref
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
  JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
  WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = %s AND tc.table_name = %s
) fk ON fk.column_name = c.column_name
WHERE c.table_schema = %s AND c.table_name = %s
ORDER BY c.ordinal_position]]):format(schema, name, schema, name, schema, name)
end

function M.sql.indexes(relation)
  return ([[SELECT i.relname AS name,
       CASE WHEN ix.indisunique THEN 1 ELSE 0 END AS uniq,
       CASE WHEN ix.indisprimary THEN 'pk' ELSE 'i' END AS origin,
       pg_get_indexdef(ix.indexrelid) AS cols
FROM pg_index ix
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = %s AND t.relname = %s ORDER BY i.relname]]):format(lit(relation.schema or 'public'), lit(relation.name))
end

function M.sql.constraints(relation)
  return ([[SELECT conname AS name, contype AS kind, pg_get_constraintdef(c.oid) AS detail
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = %s AND t.relname = %s ORDER BY conname]]):format(lit(relation.schema or 'public'), lit(relation.name))
end

--- No native DDL statement; `dblens.ddl` reconstructs it from the catalog.
function M.sql.ddl(_relation)
  return nil
end

function M.sql.page(relation, opts)
  return common.page(relation, opts, dialect)
end

function M.sql.count(relation, where)
  return common.count(relation, where, dialect)
end

function M.sql.explain(statement, analyze)
  return (analyze and 'EXPLAIN (ANALYZE, BUFFERS) ' or 'EXPLAIN ') .. statement
end

--- Planner row estimate, used to preview the blast radius of a destructive statement without
--- running it. Plain EXPLAIN plans but never executes.
function M.estimate(statement)
  return {
    sql = 'EXPLAIN (FORMAT JSON) ' .. statement,
    mode = 'raw',
    parse = function(_decoded, raw)
      local ok, decoded = pcall(vim.json.decode, vim.trim(raw))
      if not ok or type(decoded) ~= 'table' then
        return nil
      end
      local plan = decoded[1] and decoded[1].Plan
      if type(plan) ~= 'table' or type(plan['Plan Rows']) ~= 'number' then
        return nil
      end
      return math.floor(plan['Plan Rows'])
    end,
  }
end

function M.sql.affected()
  return nil
end

return M
