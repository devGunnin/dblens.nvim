--- Reconstructing a readable `CREATE TABLE` for adapters with no native DDL statement.
---
--- Pure: catalog facts in, text out, no IO. The result is meant to be read, not replayed -- the
--- catalog does not carry everything a server would need to recreate the relation exactly.
local common = require('dblens.adapters.common')
local sql = require('dblens.sql')

local M = {}

---@param adapter dblens.Adapter
---@return boolean
function M.available(adapter)
  assert(
    type(adapter) == 'table' and type(adapter.caps) == 'table',
    'ddl.available: expected an adapter'
  )
  return adapter.caps.ddl == 'reconstructed'
end

---@param column dblens.Column
---@return string  one column definition, without its trailing comma
local function column_line(column, dialect)
  assert(type(column) == 'table', 'ddl: expected a column')
  local parts = { sql.quote_ident(column.name, dialect) }
  if type(column.type) == 'string' and column.type ~= '' then
    parts[#parts + 1] = column.type
  end
  if column.notnull then
    parts[#parts + 1] = 'NOT NULL'
  end
  if type(column.default) == 'string' and vim.trim(column.default) ~= '' then
    parts[#parts + 1] = 'DEFAULT ' .. vim.trim(column.default)
  end
  return table.concat(parts, ' ')
end

--- `PRIMARY KEY (...)` in key order, or nil when the relation has no primary key.
---@param columns dblens.Column[]
---@return string?
local function primary_key_line(columns, dialect)
  assert(vim.islist(columns), 'ddl: expected a column list')
  local key = {}
  for _, column in ipairs(columns) do
    if (column.pk or 0) > 0 then
      key[#key + 1] = column
    end
  end
  if #key == 0 then
    return nil
  end
  table.sort(key, function(a, b)
    return a.pk < b.pk
  end)
  local names = {}
  for i, column in ipairs(key) do
    names[i] = sql.quote_ident(column.name, dialect)
  end
  return 'PRIMARY KEY (' .. table.concat(names, ', ') .. ')'
end

--- The primary key already has its own clause, so its constraint row is dropped.
local function is_primary(constraint)
  local kind = tostring(constraint.kind or ''):lower()
  if kind == 'p' or kind == 'primary key' then
    return true
  end
  return tostring(constraint.detail or ''):upper():match('^%s*PRIMARY KEY') ~= nil
end

--- Append table-level constraints to `body`, returning the names emitted.
---@param constraints dblens.Constraint[]?
---@return table<string, boolean>
local function append_constraints(body, constraints, dialect)
  local emitted = {}
  for _, constraint in ipairs(constraints or {}) do
    local detail = vim.trim(tostring(constraint.detail or ''))
    local name = tostring(constraint.name or '')
    if detail ~= '' and name ~= '' and not is_primary(constraint) then
      body[#body + 1] = ('CONSTRAINT %s %s'):format(sql.quote_ident(name, dialect), detail)
      emitted[name] = true
    end
  end
  return emitted
end

--- One `CREATE INDEX` statement, or nil when the index carries nothing to emit.
---
--- Postgres reports `pg_get_indexdef`, a whole statement, in `columns`; pass that through instead
--- of wrapping it in a second `CREATE INDEX`.
---@param index dblens.Index
---@return string?
local function index_statement(index, relation, dialect)
  local definition = vim.trim(tostring(index.columns or ''))
  local name = tostring(index.name or '')
  if definition == '' or name == '' then
    return nil
  end
  if definition:upper():match('^CREATE%s') then
    return (definition:gsub(';%s*$', '')) .. ';'
  end
  local names = {}
  for part in definition:gmatch('[^,]+') do
    local column = vim.trim(part)
    if column ~= '' then
      names[#names + 1] = sql.quote_ident(column, dialect)
    end
  end
  if #names == 0 then
    return nil
  end
  return ('CREATE %sINDEX %s ON %s (%s);'):format(
    index.unique and 'UNIQUE ' or '',
    sql.quote_ident(name, dialect),
    common.qualify(relation, dialect),
    table.concat(names, ', ')
  )
end

--- Build the DDL for one relation from its cached catalog facts.
---@param relation dblens.Relation
---@param info dblens.RelationInfo
---@param dialect dblens.Dialect
---@return string  a `CREATE TABLE` block, or a comment explaining why there is none
function M.reconstruct(relation, info, dialect)
  assert(type(relation) == 'table', 'ddl.reconstruct: expected a relation')
  assert(type(info) == 'table', 'ddl.reconstruct: expected relation info')
  assert(
    type(dialect) == 'table' and type(dialect.ident_quote) == 'string',
    'ddl.reconstruct: expected a dialect'
  )

  local name = common.qualify(relation, dialect)
  if info.columns == nil then
    return ('-- %s: columns are not loaded, so no DDL can be reconstructed'):format(name)
  end
  if #info.columns == 0 then
    return ('-- %s: the catalog reports no columns'):format(name)
  end

  local body = {}
  for _, column in ipairs(info.columns) do
    body[#body + 1] = column_line(column, dialect)
  end
  local pk = primary_key_line(info.columns, dialect)
  if pk then
    body[#body + 1] = pk
  end
  local emitted = append_constraints(body, info.constraints, dialect)

  local lines = {}
  if relation.kind == 'view' then
    lines[#lines + 1] = '-- view: column shape only, the SELECT body is not in the catalog'
  end
  lines[#lines + 1] = 'CREATE TABLE ' .. name .. ' ('
  for i, entry in ipairs(body) do
    lines[#lines + 1] = ('  %s%s'):format(entry, i < #body and ',' or '')
  end
  lines[#lines + 1] = ');'

  for _, index in ipairs(info.indexes or {}) do
    if not index.primary and not emitted[index.name] then
      local statement = index_statement(index, relation, dialect)
      if statement then
        lines[#lines + 1] = ''
        lines[#lines + 1] = statement
      end
    end
  end
  return table.concat(lines, '\n')
end

return M
