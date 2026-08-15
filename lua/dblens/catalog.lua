--- The per-connection schema cache: the single source of truth about a database's shape.
---
--- The tree renders it, completion reads it, fuzzy search scans it, and CRUD depends on it for
--- primary keys. It is a pure data model — loading is the session's job — so `nil` consistently
--- means "not loaded yet" and an empty list means "loaded, and there are none".
local protocol = require('dblens.protocol')

local M = {}

---@class dblens.Column
---@field name string
---@field type string
---@field notnull boolean
---@field pk integer      -- 0 when not part of the primary key, else its 1-based position
---@field default string?
---@field fk string?      -- referenced `table.column`, when any

---@class dblens.Index
---@field name string
---@field unique boolean
---@field primary boolean
---@field columns string

---@class dblens.Constraint
---@field name string
---@field kind string
---@field detail string

---@class dblens.RelationInfo
---@field relation dblens.Relation
---@field columns dblens.Column[]?
---@field indexes dblens.Index[]?
---@field constraints dblens.Constraint[]?
---@field row_count integer?

local Catalog = {}
Catalog.__index = Catalog

--- Stable key for a relation. NUL cannot occur in an identifier, so it cannot collide.
local function key_of(schema, name)
  return (schema or '') .. '\0' .. name
end
M.key_of = key_of

---@param has_schemas boolean
---@return dblens.Catalog
function M.new(has_schemas)
  assert(type(has_schemas) == 'boolean', 'catalog.new: has_schemas must be a boolean')
  return setmetatable({
    has_schemas = has_schemas,
    schema_names = nil,
    relations = {},
    info = {},
  }, Catalog)
end

--- Column index lookup by name, tolerating adapters that alias differently.
local function value(row, columns, name)
  local index = protocol.column_index(columns, name)
  if not index then
    return nil
  end
  local cell = row[index]
  if cell == protocol.NULL or cell == nil or cell == '' then
    return nil
  end
  return cell
end

---@param result dblens.ResultSet
---@return dblens.Column[]
function M.parse_columns(result)
  assert(type(result) == 'table' and result.rows, 'catalog.parse_columns: expected a result set')
  local out = {}
  for _, row in ipairs(result.rows) do
    out[#out + 1] = {
      name = value(row, result.columns, 'name') or '',
      type = value(row, result.columns, 'type') or '',
      notnull = (tonumber(value(row, result.columns, 'notnull')) or 0) ~= 0,
      pk = tonumber(value(row, result.columns, 'pk')) or 0,
      default = value(row, result.columns, 'dflt'),
      fk = value(row, result.columns, 'fk'),
    }
  end
  return out
end

---@param result dblens.ResultSet
---@return dblens.Index[]
function M.parse_indexes(result)
  local out = {}
  for _, row in ipairs(result.rows) do
    local origin = value(row, result.columns, 'origin')
    out[#out + 1] = {
      name = value(row, result.columns, 'name') or '',
      unique = (tonumber(value(row, result.columns, 'uniq')) or 0) ~= 0,
      primary = origin == 'pk',
      columns = value(row, result.columns, 'cols') or '',
    }
  end
  return out
end

---@param result dblens.ResultSet
---@return dblens.Constraint[]
function M.parse_constraints(result)
  local out = {}
  for _, row in ipairs(result.rows) do
    out[#out + 1] = {
      name = value(row, result.columns, 'name') or '',
      kind = value(row, result.columns, 'kind') or '',
      detail = value(row, result.columns, 'detail') or '',
    }
  end
  return out
end

---@param result dblens.ResultSet
---@param schema string?
---@return dblens.Relation[]
function M.parse_relations(result, schema)
  local out = {}
  for _, row in ipairs(result.rows) do
    local name = value(row, result.columns, 'name')
    if name then
      out[#out + 1] = {
        schema = schema,
        name = name,
        kind = value(row, result.columns, 'kind') == 'view' and 'view' or 'table',
      }
    end
  end
  return out
end

---@param names string[]
function Catalog:set_schemas(names)
  assert(vim.islist(names), 'catalog:set_schemas: expected a list')
  self.schema_names = names
end

---@param schema string?
---@param relations dblens.Relation[]
function Catalog:set_relations(schema, relations)
  assert(vim.islist(relations), 'catalog:set_relations: expected a list')
  self.relations[schema or ''] = relations
  for _, relation in ipairs(relations) do
    local key = key_of(relation.schema, relation.name)
    self.info[key] = self.info[key] or { relation = relation }
  end
end

---@return dblens.Relation[]? nil when that schema has not been loaded
function Catalog:get_relations(schema)
  return self.relations[schema or '']
end

---@return dblens.RelationInfo
function Catalog:info_for(relation)
  local key = key_of(relation.schema, relation.name)
  self.info[key] = self.info[key] or { relation = relation }
  return self.info[key]
end

--- Replace one loaded facet of a relation. `part` is 'columns', 'indexes' or 'constraints'.
function Catalog:set_part(relation, part, items)
  assert(
    part == 'columns' or part == 'indexes' or part == 'constraints',
    'catalog:set_part: unknown part ' .. tostring(part)
  )
  assert(vim.islist(items), 'catalog:set_part: expected a list')
  self:info_for(relation)[part] = items
end

function Catalog:set_row_count(relation, count)
  assert(count == nil or count >= 0, 'catalog:set_row_count: count must not be negative')
  self:info_for(relation).row_count = count
end

--- One column of a relation by name, or nil when it or the relation is not loaded.
---@param name string
---@return dblens.Column?
function Catalog:column(relation, name)
  assert(type(name) == 'string' and name ~= '', 'catalog:column: expected a column name')
  for _, column in ipairs(self:info_for(relation).columns or {}) do
    if column.name == name then
      return column
    end
  end
  return nil
end

--- Primary key columns, in key order. Empty when the relation has none or is not loaded.
---@return dblens.Column[]
function Catalog:primary_key(relation)
  local columns = self:info_for(relation).columns
  if not columns then
    return {}
  end
  local pk = {}
  for _, column in ipairs(columns) do
    if column.pk > 0 then
      pk[#pk + 1] = column
    end
  end
  table.sort(pk, function(a, b)
    return a.pk < b.pk
  end)
  return pk
end

--- Every loaded relation across every loaded schema, for fuzzy search and completion.
---@return dblens.Relation[]
function Catalog:all_relations()
  local out = {}
  for _, schema in ipairs(self:schema_list()) do
    for _, relation in ipairs(self.relations[schema] or {}) do
      out[#out + 1] = relation
    end
  end
  return out
end

--- Loaded schema keys in display order. The unnamed key is used by schema-less databases.
---@return string[]
function Catalog:schema_list()
  if self.has_schemas then
    return self.schema_names or {}
  end
  return { '' }
end

--- Drop every cached fact, keeping the shape. Used by an explicit refresh.
function Catalog:clear()
  self.schema_names = nil
  self.relations = {}
  self.info = {}
end

M.Catalog = Catalog
return M
