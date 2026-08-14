--- MySQL / MariaDB adapter, driven through the `mysql` client.
---
--- UNTESTED LIVE: no mysql client or server was available during development. Every statement
--- builder and the XML decoder are unit-tested against the documented output format.
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
  caps = { schemas = true, ddl = 'native', explain = true, explain_analyze = true, estimate_rows = true },
  fields = {
    { name = 'host', label = 'Host', default = 'localhost' },
    { name = 'port', label = 'Port', default = 3306 },
    { name = 'user', label = 'User' },
    { name = 'database', label = 'Database', required = true },
  },
}

function M.validate(spec)
  if type(spec.database) ~= 'string' or spec.database == '' then
    return 'mysql connection needs a `database`'
  end
  if spec.port ~= nil and type(spec.port) ~= 'number' then
    return 'mysql `port` must be a number'
  end
  return nil
end

function M.describe(spec)
  return ('%s@%s:%s/%s'):format(spec.user or '$USER', spec.host or 'localhost', spec.port or 3306, spec.database)
end

--- The password goes through MYSQL_PWD, never argv, which would expose it in the process list.
function M.command(spec, secret, mode, clients)
  local argv = { clients.mysql, '--default-character-set=utf8mb4', '--connect-timeout=10' }
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
  argv[#argv + 1] = spec.database

  local env = secret and { MYSQL_PWD = secret } or nil
  return { argv = argv, env = env }
end

local ENTITIES = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }

local function unescape(text)
  return (text:gsub('&(#?[%w]+);', function(name)
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
  end))
end

--- Parse one `<row>...</row>` block into ordered field names and values.
local function parse_row(block)
  local names, values = {}, {}
  for attrs, body in block:gmatch('<field([^>]*)>(.-)</field>') do
    names[#names + 1] = unescape(attrs:match('name="([^"]*)"') or '')
    values[#values + 1] = unescape(body)
  end
  -- self-closing fields carry xsi:nil and therefore no body
  for attrs in block:gmatch('<field([^>]-)/>') do
    names[#names + 1] = unescape(attrs:match('name="([^"]*)"') or '')
    values[#values + 1] = protocol.NULL
  end
  return names, values
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

  for block in stdout:gmatch('<row>(.-)</row>') do
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

M.sql = {}

function M.sql.schemas()
  return [[SELECT schema_name AS name FROM information_schema.schemata
WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY schema_name]]
end

function M.sql.relations(schema)
  return ([[SELECT table_name AS name,
       CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS kind
FROM information_schema.tables WHERE table_schema = %s ORDER BY kind DESC, table_name]]):format(lit(schema))
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
GROUP BY index_name, non_unique ORDER BY index_name]]):format(lit(relation.schema or ''), lit(relation.name))
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

return M
