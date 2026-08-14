--- Statement fragments shared by every adapter.
---
--- Paging, sorting and filtering are ANSI enough that all three clients take the same shape;
--- only quoting differs, and that comes in via the dialect.
local sql = require('dblens.sql')

local M = {}

---@class dblens.Relation
---@field schema string?
---@field name string
---@field kind 'table'|'view'

--- Fully-qualified, correctly quoted relation reference.
---@param relation dblens.Relation
---@param dialect dblens.Dialect
---@return string
function M.qualify(relation, dialect)
  assert(type(relation) == 'table' and relation.name, 'common.qualify: relation needs a name')
  local name = sql.quote_ident(relation.name, dialect)
  if relation.schema and relation.schema ~= '' then
    return sql.quote_ident(relation.schema, dialect) .. '.' .. name
  end
  return name
end

---@class dblens.PageOpts
---@field limit integer
---@field offset integer
---@field order_by { column: string, desc: boolean }?
---@field where string?  -- raw SQL predicate typed by the user

--- Check a user-typed filter predicate before it is spliced into generated SQL.
---
--- The filter bar takes raw SQL by design, but a predicate must stay one read-only expression:
--- clients fed `1=1; DROP TABLE t` would run both statements.
---@param where string?
---@return string? error message, nil when the predicate is safe to splice
function M.check_predicate(where)
  if not where or vim.trim(where) == '' then
    return nil
  end
  local statements = sql.split(where)
  if #statements > 1 then
    return 'filter must be a single expression (remove the `;`)'
  end
  -- A bare predicate has no leading verb; any recognised write verb means this is not one.
  if sql.classify('SELECT 1 WHERE ' .. where).write then
    return 'filter must not contain a write statement'
  end
  for _, statement in ipairs(sql.classify_all(where)) do
    if statement.write then
      return 'filter must not contain a write statement'
    end
  end
  return nil
end

local function where_clause(where)
  if not where or vim.trim(where) == '' then
    return ''
  end
  assert(M.check_predicate(where) == nil, 'common: unsafe predicate reached SQL generation')
  return ' WHERE ' .. vim.trim(where)
end

local function order_clause(order_by, dialect)
  if not order_by then
    return ''
  end
  assert(type(order_by.column) == 'string', 'common: order_by needs a column')
  return (' ORDER BY %s %s'):format(sql.quote_ident(order_by.column, dialect), order_by.desc and 'DESC' or 'ASC')
end

--- `SELECT * FROM rel [WHERE ...] [ORDER BY ...] LIMIT n OFFSET k`.
---@param relation dblens.Relation
---@param opts dblens.PageOpts
---@param dialect dblens.Dialect
---@return string
function M.page(relation, opts, dialect)
  assert(type(opts.limit) == 'number' and opts.limit > 0, 'common.page: limit must be positive')
  assert(type(opts.offset) == 'number' and opts.offset >= 0, 'common.page: offset must not be negative')
  return ('SELECT * FROM %s%s%s LIMIT %d OFFSET %d'):format(
    M.qualify(relation, dialect),
    where_clause(opts.where),
    order_clause(opts.order_by, dialect),
    opts.limit,
    opts.offset
  )
end

--- `SELECT count(*) FROM rel [WHERE ...]`.
function M.count(relation, where, dialect)
  return ('SELECT count(*) AS n FROM %s%s'):format(M.qualify(relation, dialect), where_clause(where))
end

--- Predicate matching exactly the given column values, for row-targeted CRUD.
---@param values { column: string, value: any }[]
---@param dialect dblens.Dialect
---@return string
function M.match_where(values, dialect)
  assert(#values > 0, 'common.match_where: refusing to build an empty predicate')
  local parts = {}
  for _, entry in ipairs(values) do
    local column = sql.quote_ident(entry.column, dialect)
    if entry.value == nil or entry.value == vim.NIL then
      parts[#parts + 1] = column .. ' IS NULL'
    else
      parts[#parts + 1] = column .. ' = ' .. sql.quote_literal(tostring(entry.value), dialect)
    end
  end
  return table.concat(parts, ' AND ')
end

return M
