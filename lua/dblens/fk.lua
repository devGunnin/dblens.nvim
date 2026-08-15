--- What a column's foreign-key metadata points at.
---
--- `catalog.Column.fk` arrives in two shapes, because two shapes are what the engines can give
--- cheaply. Five adapters emit `table.column` (sqlite, postgres, mysql, mariadb, mssql); duckdb
--- emits the constraint text `FOREIGN KEY (a) REFERENCES t(x)`, since `duckdb_constraints()` is
--- the only place it holds the fact at all. Both are parsed to the same target here, so the
--- navigation on top of them is written once.
---
--- Pure: this module reads metadata and resolves names against a catalog. It builds no SQL and
--- runs nothing.
local M = {}

---@class dblens.FkTarget
---@field schema string?    -- set only when the metadata qualified the table
---@field table string
---@field column string?    -- nil when the metadata names no target column
---@field composite boolean -- the key spans several columns, so one column narrows it only partly

--- A keyword as a case-insensitive Lua pattern. duckdb emits `REFERENCES` uppercase; nothing
--- promises it always will.
local function insensitive(word)
  return (
    word:gsub('%a', function(char)
      return ('[%s%s]'):format(char:upper(), char:lower())
    end)
  )
end

--- `(sources) REFERENCES target (targets)` — one match per constraint, so a `string_agg` of
--- several constraint texts yields several targets.
local CONSTRAINT_PATTERN = '%(([^()]*)%)%s*'
  .. insensitive('REFERENCES')
  .. '%s*(.-)%s*%(([^()]*)%)'

local REFERENCES = insensitive('REFERENCES')

--- Drop the delimiters an engine put around a name that needed them.
local function unquote(raw)
  local text = vim.trim(raw)
  local first, last = text:sub(1, 1), text:sub(-1)
  if #text < 2 then
    return text
  end
  if first == '"' and last == '"' then
    return (text:sub(2, -2):gsub('""', '"'))
  end
  if first == '`' and last == '`' then
    return (text:sub(2, -2):gsub('``', '`'))
  end
  if first == '[' and last == ']' then
    return text:sub(2, -2)
  end
  return text
end

--- Delimiters an engine may put around a name, and what closes each.
local CLOSERS = { ['"'] = '"', ['`'] = '`', ['['] = ']' }

--- Split a possibly-qualified name into its unquoted parts, on the dots BETWEEN delimiters.
---
--- `"sch"."t"` is two parts. Unquoting the whole string first saw one pair of quotes around it
--- and left `sch"."t` — a name no catalog holds, so `gf` reported the referenced table was not
--- loaded when it was there all along.
---@param text string
---@return string[]
local function split_qualified(text)
  local trimmed = vim.trim(text)
  local parts, buffer, i = {}, {}, 1
  while i <= #trimmed do
    local char = trimmed:sub(i, i)
    local closer = CLOSERS[char]
    if closer then
      local at = trimmed:find(closer, i + 1, true)
      -- A doubled delimiter is one escaped character inside the name, not the end of it.
      while at and trimmed:sub(at + 1, at + 1) == closer do
        at = trimmed:find(closer, at + 2, true)
      end
      local body = at and trimmed:sub(i + 1, at - 1) or trimmed:sub(i + 1)
      buffer[#buffer + 1] = (body:gsub(closer .. closer, closer))
      i = (at or #trimmed) + 1
    elseif char == '.' then
      parts[#parts + 1] = table.concat(buffer)
      buffer = {}
      i = i + 1
    else
      buffer[#buffer + 1] = char
      i = i + 1
    end
  end
  parts[#parts + 1] = table.concat(buffer)
  return parts
end

--- A comma-separated identifier list. Adequate for catalog output, which does not put a comma
--- inside a name; a name that does is a limitation, not a correctness hole — the worst case is
--- a target we decline to follow.
---@return string[]
local function split_list(text)
  local out = {}
  for part in tostring(text):gmatch('[^,]+') do
    local name = unquote(part)
    if name ~= '' then
      out[#out + 1] = name
    end
  end
  return out
end

--- Split `table.column` at the LAST dot: no adapter qualifies the table with its schema, so
--- everything before the final dot belongs to the table name.
---@return dblens.FkTarget?
local function pair_target(text)
  local name = vim.trim(text)
  if name == '' then
    return nil
  end
  local at = name:match('^.*()%.')
  if not at then
    return nil
  end
  local table_name = unquote(name:sub(1, at - 1))
  local column = unquote(name:sub(at + 1))
  if table_name == '' then
    return nil
  end
  -- sqlite's `pragma_foreign_key_list` leaves `to` NULL for a reference to the implicit primary
  -- key, and the adapter COALESCEs that to an empty string.
  return { table = table_name, column = column ~= '' and column or nil, composite = false }
end

--- Targets read from duckdb's constraint text, mapping THIS column to the target column at the
--- same position, so a composite key still follows the right pair.
---@return dblens.FkTarget[]
local function constraint_targets(text, source_column)
  local out = {}
  for sources, target, targets in text:gmatch(CONSTRAINT_PATTERN) do
    local source_names, target_names = split_list(sources), split_list(targets)
    local at = nil
    for index, name in ipairs(source_names) do
      if name == source_column then
        at = index
      end
    end
    -- The constraint text may qualify the table (`"sch"."t"`); the last part is its own name.
    local qualified = split_qualified(target)
    local table_name = qualified[#qualified]
    if table_name ~= '' then
      out[#out + 1] = {
        schema = #qualified > 1 and qualified[#qualified - 1] or nil,
        table = table_name,
        column = at and target_names[at] or nil,
        composite = #source_names > 1,
      }
    end
  end
  return out
end

--- Everything `fk` points at, for the column it was recorded against.
---
--- Returns an empty list rather than an error when nothing is parseable: an unrecognised shape
--- means "this engine cannot tell us where to go", which the caller reports as a no-op.
---@param fk string?          -- `catalog.Column.fk`
---@param source_column string  -- the column carrying it, needed to pair up a composite key
---@return dblens.FkTarget[]
function M.targets(fk, source_column)
  assert(
    type(source_column) == 'string' and source_column ~= '',
    'fk.targets: needs the source column name'
  )
  if type(fk) ~= 'string' or vim.trim(fk) == '' then
    return {}
  end
  if fk:find(REFERENCES) then
    return constraint_targets(fk, source_column)
  end
  local out = {}
  for _, part in ipairs(vim.split(fk, ',', { plain = true })) do
    local target = pair_target(part)
    if target then
      out[#out + 1] = target
    end
  end
  return out
end

--- The loaded relation a target names.
---
--- Most foreign-key metadata carries no schema, so a name is looked up in the referencing
--- relation's own schema first: on postgres and mysql the same table name commonly exists in
--- several. Where the metadata DID qualify the table (duckdb's constraint text can), that schema
--- decides instead — it is the one the engine itself named.
---@param catalog dblens.Catalog
---@param from dblens.Relation   -- the relation the FK was read from
---@param name string
---@param schema string?         -- the schema the metadata named, when it named one
---@return dblens.Relation?
function M.resolve(catalog, from, name, schema)
  assert(type(name) == 'string' and name ~= '', 'fk.resolve: needs a target name')
  local prefer = schema or from.schema or ''
  local fallback = nil
  for _, relation in ipairs(catalog:all_relations()) do
    if relation.name == name then
      if (relation.schema or '') == prefer then
        return relation
      end
      fallback = fallback or relation
    end
  end
  -- A schema the engine named explicitly is not a preference: a table of that name in another
  -- schema is a different table, and browsing it would be a wrong answer rather than no answer.
  if schema then
    return nil
  end
  return fallback
end

return M
