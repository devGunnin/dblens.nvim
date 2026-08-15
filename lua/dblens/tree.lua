--- Flattens a catalog plus an expansion set into the ordered node list the sidebar draws.
---
--- Pure: no vim API beyond table helpers, no icons, no highlights. The sidebar decides how a
--- node looks; this module decides only what exists and in what order.
local M = {}

---@class dblens.Node
---@field id string           -- stable across reloads; the expansion set is keyed by it
---@field kind 'connection'|'schema'|'relation'|'folder'|'column'|'index'|'constraint'|'empty'
---@field depth integer       -- 0 for the connection row
---@field label string
---@field detail string?      -- dimmed secondary text
---@field badges string[]?    -- 'PK', 'FK', 'NN'
---@field expandable boolean
---@field expanded boolean
---@field loading boolean
---@field schema string?
---@field relation dblens.Relation?
---@field folder 'indexes'|'constraints'?

local SEP = '\0'

function M.connection_id()
  return 'c'
end

function M.schema_id(schema)
  return 's' .. SEP .. schema
end

function M.relation_id(relation)
  return 'r' .. SEP .. (relation.schema or '') .. SEP .. relation.name
end

function M.folder_id(relation, folder)
  return 'f' .. SEP .. (relation.schema or '') .. SEP .. relation.name .. SEP .. folder
end

---@class dblens.TreeInput
---@field name string          -- connection name
---@field detail string?       -- connection target description
---@field catalog dblens.Catalog
---@field expanded table<string, boolean>
---@field loading table<string, boolean>

local function column_badges(column)
  local badges = {}
  if column.pk > 0 then
    badges[#badges + 1] = 'PK'
  end
  if column.fk then
    badges[#badges + 1] = 'FK'
  end
  if column.notnull and column.pk == 0 then
    badges[#badges + 1] = 'NN'
  end
  return badges
end

local Builder = {}
Builder.__index = Builder

function Builder.new(input)
  return setmetatable({ input = input, nodes = {} }, Builder)
end

function Builder:push(node)
  node.expanded = self.input.expanded[node.id] == true
  node.loading = self.input.loading[node.id] == true
  self.nodes[#self.nodes + 1] = node
  return node
end

--- Emit a "nothing here" row so an expanded-but-empty branch never looks broken.
function Builder:push_empty(depth, text)
  self:push({
    id = 'empty' .. SEP .. depth .. SEP .. #self.nodes,
    kind = 'empty',
    depth = depth,
    label = text,
    expandable = false,
  })
end

function Builder:add_columns(relation, depth)
  local columns = self.input.catalog:info_for(relation).columns
  if not columns then
    return
  end
  if #columns == 0 then
    self:push_empty(depth, 'no columns')
  end
  for _, column in ipairs(columns) do
    self:push({
      id = 'col' .. SEP .. (relation.schema or '') .. SEP .. relation.name .. SEP .. column.name,
      kind = 'column',
      depth = depth,
      label = column.name,
      detail = column.type ~= '' and column.type:lower() or nil,
      badges = column_badges(column),
      expandable = false,
      schema = relation.schema,
      relation = relation,
    })
  end
end

local FOLDER_LABEL = { indexes = 'Indexes', constraints = 'Constraints' }

function Builder:add_folder(relation, folder, depth)
  local items = self.input.catalog:info_for(relation)[folder]
  local node = self:push({
    id = M.folder_id(relation, folder),
    kind = 'folder',
    depth = depth,
    label = FOLDER_LABEL[folder],
    detail = items and ('%d'):format(#items) or nil,
    expandable = true,
    schema = relation.schema,
    relation = relation,
    folder = folder,
  })
  if not node.expanded or not items then
    return
  end
  if #items == 0 then
    self:push_empty(depth + 1, 'none')
  end
  for _, item in ipairs(items) do
    self:push({
      id = M.folder_id(relation, folder) .. SEP .. item.name,
      kind = folder == 'indexes' and 'index' or 'constraint',
      depth = depth + 1,
      label = item.name,
      detail = folder == 'indexes' and item.columns or item.detail,
      badges = folder == 'indexes' and item.unique and { item.primary and 'PK' or 'UQ' } or nil,
      expandable = false,
      schema = relation.schema,
      relation = relation,
    })
  end
end

function Builder:add_relation(relation, depth)
  local info = self.input.catalog:info_for(relation)
  local node = self:push({
    id = M.relation_id(relation),
    kind = 'relation',
    depth = depth,
    label = relation.name,
    detail = info.row_count and ('%d rows'):format(info.row_count) or nil,
    expandable = true,
    schema = relation.schema,
    relation = relation,
  })
  if not node.expanded then
    return
  end
  self:add_columns(relation, depth + 1)
  self:add_folder(relation, 'indexes', depth + 1)
  self:add_folder(relation, 'constraints', depth + 1)
end

function Builder:add_schema_body(schema, depth)
  local relations = self.input.catalog:get_relations(schema)
  if not relations then
    return
  end
  if #relations == 0 then
    self:push_empty(depth, 'no tables')
  end
  for _, relation in ipairs(relations) do
    self:add_relation(relation, depth)
  end
end

function Builder:add_schemas(depth)
  local catalog = self.input.catalog
  if not catalog.has_schemas then
    self:add_schema_body('', depth)
    return
  end
  if not catalog.schema_names then
    return
  end
  if #catalog.schema_names == 0 then
    self:push_empty(depth, 'no schemas')
  end
  for _, schema in ipairs(catalog.schema_names) do
    local node = self:push({
      id = M.schema_id(schema),
      kind = 'schema',
      depth = depth,
      label = schema,
      expandable = true,
      schema = schema,
    })
    if node.expanded then
      self:add_schema_body(schema, depth + 1)
    end
  end
end

--- Build the visible node list.
---@param input dblens.TreeInput
---@return dblens.Node[]
function M.flatten(input)
  assert(type(input) == 'table' and input.catalog, 'tree.flatten: needs a catalog')
  assert(type(input.name) == 'string', 'tree.flatten: needs a connection name')
  local builder = Builder.new({
    name = input.name,
    detail = input.detail,
    catalog = input.catalog,
    expanded = input.expanded or {},
    loading = input.loading or {},
  })

  local root = builder:push({
    id = M.connection_id(),
    kind = 'connection',
    depth = 0,
    label = input.name,
    detail = input.detail,
    expandable = true,
  })
  if root.expanded then
    builder:add_schemas(1)
  end
  return builder.nodes
end

--- Index of the first node matching `id`, or nil.
---@param nodes dblens.Node[]
---@return integer?
function M.index_of(nodes, id)
  for i, node in ipairs(nodes) do
    if node.id == id then
      return i
    end
  end
  return nil
end

return M
