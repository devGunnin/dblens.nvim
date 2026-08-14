--- Decoding of the control-character record format every CLI adapter is configured to emit.
---
--- All three clients can be told to separate fields and records with ASCII control codes and
--- to print a chosen sentinel for NULL. That makes the wire format identical across adapters
--- and immune to values containing commas, tabs, quotes or newlines.
local M = {}

--- ASCII unit/record separators, and a group separator standing in for NULL.
M.FIELD_SEP = '\031'
M.RECORD_SEP = '\030'
M.NULL_SENTINEL = '\029'

--- SQL NULL. `vim.NIL` is used so a row stays a gapless array and JSON export is direct.
M.NULL = vim.NIL

---@class dblens.ResultSet
---@field columns string[]
---@field rows any[][]        -- string cells, or M.NULL
---@field malformed integer   -- rows whose field count did not match the header

local function split_fields(record, null_sentinel)
  local fields, from = {}, 1
  while true do
    local at = record:find(M.FIELD_SEP, from, true)
    local raw = at and record:sub(from, at - 1) or record:sub(from)
    fields[#fields + 1] = raw == null_sentinel and M.NULL or raw
    if not at then
      return fields
    end
    from = at + 1
  end
end

--- Split on the record separator, dropping the trailing empty record the clients emit.
local function split_records(text)
  local records, from = {}, 1
  while from <= #text do
    local at = text:find(M.RECORD_SEP, from, true)
    if not at then
      records[#records + 1] = text:sub(from)
      break
    end
    records[#records + 1] = text:sub(from, at - 1)
    from = at + 1
  end
  return records
end

--- Decode client stdout into a result set.
---
--- Short rows are padded with NULL and counted in `malformed` rather than dropped: a BLOB can
--- legitimately contain our separator bytes, and losing the row silently would be worse than
--- showing it with a visible warning.
---@param stdout string
---@param opts { header: boolean?, null_sentinel: string?, columns: string[]? }?
---@return dblens.ResultSet
function M.decode(stdout, opts)
  assert(type(stdout) == 'string', 'protocol.decode: expected string')
  opts = opts or {}
  local null_sentinel = opts.null_sentinel or M.NULL_SENTINEL
  local want_header = opts.header ~= false

  local records = split_records(stdout)
  local columns, malformed = opts.columns and vim.deepcopy(opts.columns) or {}, 0
  local first = 1
  -- An empty result yields no output at all, so a caller-supplied column list is the only way
  -- to keep headers for a zero-row table.
  if want_header and #records > 0 then
    local header = split_fields(records[1], null_sentinel)
    columns = {}
    for i, name in ipairs(header) do
      columns[i] = name == M.NULL and '' or name
    end
    first = 2
  end

  local rows = {}
  for i = first, #records do
    local fields = split_fields(records[i], null_sentinel)
    if #columns > 0 and #fields ~= #columns then
      malformed = malformed + 1
      for j = #fields + 1, #columns do
        fields[j] = M.NULL
      end
    end
    rows[#rows + 1] = fields
  end

  return { columns = columns, rows = rows, malformed = malformed }
end

--- Render a cell for places that need plain text (export, yank, detail view).
---@param cell any
---@return string
function M.tostring(cell)
  if cell == M.NULL or cell == nil then
    return ''
  end
  assert(type(cell) == 'string', 'protocol.tostring: cells are strings or NULL')
  return cell
end

--- Index of a column by name, or nil.
function M.column_index(columns, name)
  for i, column in ipairs(columns) do
    if column == name then
      return i
    end
  end
  return nil
end

return M
