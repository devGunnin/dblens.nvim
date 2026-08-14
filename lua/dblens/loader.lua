--- Populates a session's catalog. The only module that knows introspection is asynchronous.
---
--- Loads are idempotent and lazy: the sidebar asks for a branch when the user expands it, and a
--- second ask for an already-loaded branch is answered from the catalog without a round trip.
local catalog = require('dblens.catalog')
local protocol = require('dblens.protocol')

local M = {}

--- sqlite has no constraint catalog, so derive what is knowable from columns and indexes.
---@return dblens.Constraint[]
local function derive_constraints(info)
  local out = {}
  local pk = {}
  for _, column in ipairs(info.columns or {}) do
    if column.pk > 0 then
      pk[#pk + 1] = column.name
    end
    if column.fk then
      out[#out + 1] =
        { name = column.name, kind = 'FOREIGN KEY', detail = column.name .. ' -> ' .. column.fk }
    end
  end
  if #pk > 0 then
    table.insert(
      out,
      1,
      { name = 'primary key', kind = 'PRIMARY KEY', detail = table.concat(pk, ', ') }
    )
  end
  for _, index in ipairs(info.indexes or {}) do
    if index.unique and not index.primary then
      out[#out + 1] = { name = index.name, kind = 'UNIQUE', detail = index.columns }
    end
  end
  return out
end

---@param session dblens.Session
---@param on_done fun(err: string?)
function M.schemas(session, on_done)
  if not session.adapter.caps.schemas then
    on_done(nil)
    return
  end
  if session.catalog.schema_names then
    on_done(nil)
    return
  end
  session:run(session.adapter.sql.schemas(), {}, function(result, err)
    if err then
      on_done(err)
      return
    end
    local names = {}
    for _, row in ipairs(result.rows) do
      names[#names + 1] = protocol.tostring(row[1])
    end
    session.catalog:set_schemas(names)
    on_done(nil)
  end)
end

---@param schema string?  '' for schema-less databases
function M.relations(session, schema, on_done)
  if session.catalog:get_relations(schema) then
    on_done(nil)
    return
  end
  session:run(session.adapter.sql.relations(schema), {}, function(result, err)
    if err then
      on_done(err)
      return
    end
    session.catalog:set_relations(
      schema,
      catalog.parse_relations(result, schema ~= '' and schema or nil)
    )
    on_done(nil)
  end)
end

local PARSERS = {
  columns = catalog.parse_columns,
  indexes = catalog.parse_indexes,
  constraints = catalog.parse_constraints,
}

--- Load one facet of a relation. `constraints` falls back to derivation when the adapter has no
--- constraint catalog to query.
---@param part 'columns'|'indexes'|'constraints'
function M.part(session, relation, part, on_done)
  assert(PARSERS[part], 'loader.part: unknown part ' .. tostring(part))
  local info = session.catalog:info_for(relation)
  if info[part] then
    on_done(nil)
    return
  end

  local statement = session.adapter.sql[part](relation)
  if not statement then
    session.catalog:set_part(
      relation,
      part,
      part == 'constraints' and derive_constraints(info) or {}
    )
    on_done(nil)
    return
  end
  session:run(statement, {}, function(result, err)
    if err then
      on_done(err)
      return
    end
    session.catalog:set_part(relation, part, PARSERS[part](result))
    on_done(nil)
  end)
end

--- Columns, indexes and constraints together, in the order constraint derivation needs.
function M.relation_details(session, relation, on_done)
  M.part(session, relation, 'columns', function(err)
    if err then
      on_done(err)
      return
    end
    M.part(session, relation, 'indexes', function(index_err)
      if index_err then
        on_done(index_err)
        return
      end
      M.part(session, relation, 'constraints', on_done)
    end)
  end)
end

--- Row count for a relation, cached on the catalog.
function M.row_count(session, relation, on_done)
  session:run(session.adapter.sql.count(relation, nil), {}, function(result, err)
    if err then
      on_done(nil, err)
      return
    end
    local count = tonumber(protocol.tostring(result.rows[1] and result.rows[1][1] or ''))
    session.catalog:set_row_count(relation, count)
    on_done(count, nil)
  end)
end

return M
