--- Turning parsed CSV into the INSERT statements an import would run.
---
--- Pure: this module builds SQL text and runs nothing. Every value becomes a LITERAL through
--- `mutate.insert`, which quotes it for the dialect — nothing here concatenates a cell into a
--- statement, so a cell holding `'); DROP TABLE x;--` imports as the eighteen characters it is.
---
--- The mapping is by HEADER NAME, and a name the table does not have is refused rather than
--- guessed at or dropped: importing into the wrong column silently is worse than not importing.
local mutate = require('dblens.mutate')

local M = {}

---@class dblens.ImportPlan
---@field relation dblens.Relation
---@field columns string[]         -- the table columns the CSV sets, in CSV order
---@field unset string[]           -- table columns the file does not mention
---@field changes dblens.Change[]  -- one INSERT per data row, in file order
---@field rows integer

--- The table column each CSV header names.
---
--- Exact match first, then case-insensitive: engines differ on the case they report, and a header
--- written `ID` for a column called `id` is the same column. An ambiguous case-insensitive match
--- is refused, because picking one of two would be a guess.
---@param header any[]
---@param columns string[]
---@return string[]? mapping, string? error
local function map_header(header, columns)
  local exact, folded, ambiguous = {}, {}, {}
  for _, name in ipairs(columns) do
    exact[name] = name
    local key = name:lower()
    if folded[key] then
      ambiguous[key] = true
    end
    folded[key] = name
  end

  local mapping, taken = {}, {}
  for index, cell in ipairs(header) do
    if type(cell) ~= 'string' or vim.trim(cell) == '' then
      return nil, ('CSV column %d has no name in the header row'):format(index)
    end
    local name = vim.trim(cell)
    local target = exact[name]
    if not target then
      if ambiguous[name:lower()] then
        return nil, ('`%s` matches more than one column of this table, case aside'):format(name)
      end
      target = folded[name:lower()]
    end
    if not target then
      return nil, ('the table has no column named `%s`'):format(name)
    end
    if taken[target] then
      return nil, ('`%s` appears twice in the header row'):format(target)
    end
    taken[target] = true
    mapping[index] = target
  end
  return mapping, nil
end

--- Table columns no CSV column maps to. They keep their default, which the preview states.
---@return string[]
local function unset_columns(columns, mapping)
  local mapped = {}
  for _, name in ipairs(mapping) do
    mapped[name] = true
  end
  local out = {}
  for _, name in ipairs(columns) do
    if not mapped[name] then
      out[#out + 1] = name
    end
  end
  return out
end

--- Build the INSERTs for a parsed file.
---
--- `rows[1]` is the header. A row whose width does not match it is an error naming the file row,
--- because a short row would otherwise silently shift every value one column left.
---@param relation dblens.Relation
---@param rows any[][]          -- straight from `csv.parse`
---@param columns string[]      -- the table's own columns, from the catalog
---@param dialect dblens.Dialect
---@return dblens.ImportPlan? plan, string? error
function M.plan(relation, rows, columns, dialect)
  assert(type(relation) == 'table' and relation.name, 'import.plan: needs a relation')
  assert(vim.islist(rows), 'import.plan: expected parsed CSV rows')
  assert(vim.islist(columns), 'import.plan: expected the table columns')
  if #columns == 0 then
    return nil, ('the columns of `%s` are not loaded'):format(relation.name)
  end
  local header = rows[1]
  if not header then
    return nil, 'the file is empty'
  end
  if #rows == 1 then
    return nil, 'the file holds a header row and no data'
  end

  local mapping, problem = map_header(header, columns)
  if not mapping then
    return nil, problem
  end

  local changes = {}
  for index = 2, #rows do
    local row = rows[index]
    if #row ~= #mapping then
      return nil,
        ('row %d has %d value(s), but the header names %d column(s)'):format(index, #row, #mapping)
    end
    local values = {}
    for at, name in ipairs(mapping) do
      -- Straight through: `mutate.insert` writes protocol.NULL as NULL and quotes everything else.
      values[at] = { column = name, value = row[at] }
    end
    changes[#changes + 1] = mutate.insert(relation, values, dialect)
  end

  return {
    relation = relation,
    columns = mapping,
    unset = unset_columns(columns, mapping),
    changes = changes,
    rows = #changes,
  },
    nil
end

return M
