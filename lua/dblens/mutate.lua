--- Builders for the statements the grid's CRUD flows generate.
---
--- Pure: this module writes SQL text, it never executes anything. Every row-targeted change
--- carries a `guard` — a `count(*)` over the same predicate — which the executor runs first and
--- which must return exactly 1. That is what makes editing a row without a primary key safe:
--- an ambiguous predicate is refused rather than applied to several rows.
local common = require('dblens.adapters.common')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local M = {}

---@class dblens.KeyValue
---@field column string
---@field value any  -- string or protocol.NULL

---@class dblens.Change
---@field kind 'update'|'insert'|'delete'
---@field relation dblens.Relation
---@field sql string
---@field where string?   -- nil for insert
---@field guard string?   -- count(*) that must return exactly 1 before `sql` runs
---@field summary string  -- one line for the confirmation preview

local function literal(value, dialect)
  if value == nil or value == protocol.NULL then
    return 'NULL'
  end
  return sql.quote_literal(tostring(value), dialect)
end

--- Identify the row a grid cell belongs to.
---
--- Prefers the primary key. Falls back to every column present in the result, which is only
--- usable because the guard proves the predicate matches exactly one row.
---@param catalog dblens.Catalog
---@param relation dblens.Relation
---@param columns string[]  -- columns of the displayed result
---@param row any[]
---@return dblens.KeyValue[]? key, string? error
function M.row_key(catalog, relation, columns, row)
  assert(vim.islist(columns) and vim.islist(row), 'mutate.row_key: expected column and row lists')
  if #columns == 0 then
    return nil, 'the result has no columns to identify a row by'
  end

  local by_name = {}
  for i, name in ipairs(columns) do
    by_name[name] = row[i]
  end

  local pk = catalog:primary_key(relation)
  if #pk > 0 then
    local key = {}
    for _, column in ipairs(pk) do
      if by_name[column.name] == nil then
        key = nil
        break
      end
      key[#key + 1] = { column = column.name, value = by_name[column.name] }
    end
    if key then
      return key, nil
    end
  end

  local key = {}
  for i, name in ipairs(columns) do
    key[#key + 1] = { column = name, value = row[i] }
  end
  return key, nil
end

--- Whether the key came from a real primary key, which the preview reports to the user.
---@return boolean
function M.key_is_primary(catalog, relation, key)
  local pk = catalog:primary_key(relation)
  if #pk == 0 or #pk ~= #key then
    return false
  end
  for i, column in ipairs(pk) do
    if key[i].column ~= column.name then
      return false
    end
  end
  return true
end

local function short(value)
  if value == nil or value == protocol.NULL then
    return 'NULL'
  end
  local text = tostring(value):gsub('%s+', ' ')
  return #text > 40 and (text:sub(1, 39) .. '…') or text
end

--- `UPDATE rel SET col = value WHERE <key>`.
---@return dblens.Change
function M.update(relation, key, column, value, dialect)
  assert(type(column) == 'string' and column ~= '', 'mutate.update: needs a column')
  local where = common.match_where(key, dialect)
  local target = common.qualify(relation, dialect)
  return {
    kind = 'update',
    relation = relation,
    where = where,
    sql = ('UPDATE %s SET %s = %s WHERE %s'):format(target, sql.quote_ident(column, dialect), literal(value, dialect), where),
    guard = ('SELECT count(*) AS n FROM %s WHERE %s'):format(target, where),
    summary = ('set %s = %s'):format(column, short(value)),
  }
end

--- `DELETE FROM rel WHERE <key>`.
---@return dblens.Change
function M.delete(relation, key, dialect)
  local where = common.match_where(key, dialect)
  local target = common.qualify(relation, dialect)
  return {
    kind = 'delete',
    relation = relation,
    where = where,
    sql = ('DELETE FROM %s WHERE %s'):format(target, where),
    guard = ('SELECT count(*) AS n FROM %s WHERE %s'):format(target, where),
    summary = ('delete 1 row from %s'):format(relation.name),
  }
end

--- `INSERT INTO rel (cols) VALUES (...)`. No guard: an insert targets no existing row.
---@param values dblens.KeyValue[]
---@return dblens.Change
function M.insert(relation, values, dialect)
  assert(#values > 0, 'mutate.insert: refusing to build an insert with no columns')
  local names, literals = {}, {}
  for _, entry in ipairs(values) do
    names[#names + 1] = sql.quote_ident(entry.column, dialect)
    literals[#literals + 1] = literal(entry.value, dialect)
  end
  return {
    kind = 'insert',
    relation = relation,
    sql = ('INSERT INTO %s (%s) VALUES (%s)'):format(
      common.qualify(relation, dialect),
      table.concat(names, ', '),
      table.concat(literals, ', ')
    ),
    summary = ('insert 1 row into %s'):format(relation.name),
  }
end

--- INSERT text for a whole displayed row, used by "yank row as INSERT".
---@return string
function M.insert_text(relation, columns, row, dialect)
  local values = {}
  for i, name in ipairs(columns) do
    values[#values + 1] = { column = name, value = row[i] }
  end
  return M.insert(relation, values, dialect).sql .. ';'
end

return M
