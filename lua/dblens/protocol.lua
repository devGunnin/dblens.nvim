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

--- How many bytes of `text` end on a record boundary, or 0 when no record is complete yet.
---
--- A streamed read is handed the client's output at arbitrary byte offsets, so it can only decode
--- the part that ends where a record does. This is that rule for the control-character protocol.
---@param text string
---@return integer
function M.record_boundary(text)
  assert(type(text) == 'string', 'protocol.record_boundary: expected a string')
  -- Greedy `.*` walks to the end and backs off to the LAST separator, in one C call.
  return text:match('^.*()' .. M.RECORD_SEP) or 0
end

--- The same, for RFC 4180 CSV, where a value may legally contain the record terminator.
---
--- Quote state cannot straddle a cut: a cut only ever lands on a newline OUTSIDE quotes, so the
--- remainder always starts at the head of a record and this may always start scanning as outside.
---@param text string
---@return integer
function M.csv_boundary(text)
  assert(type(text) == 'string', 'protocol.csv_boundary: expected a string')
  local last, from, inside = 0, 1, false
  while true do
    local at = text:find(inside and '"' or '["\n]', from)
    if not at then
      return last
    end
    if text:sub(at, at) == '\n' then
      last, from = at, at + 1
    elseif not inside then
      inside, from = true, at + 1
    elseif text:sub(at + 1, at + 1) == '"' then
      -- `""` is an escaped quote inside the value; a lone one closes it.
      from = at + 2
    else
      inside, from = false, at + 1
    end
  end
end

---@class dblens.RowReader
---@field push fun(chunk: string): any[][]?, string?  -- rows completed by this chunk
---@field finish fun(): any[][]?, string?             -- rows left in the tail
---@field columns fun(): string[]
---@field malformed fun(): integer

--- Decode client output as it arrives, one chunk at a time.
---
--- `boundary` is what makes this incremental: it says how much of the buffer is whole records, and
--- only that much is decoded. An adapter with no such rule (its decoder needs the whole output to
--- tell rows from the client's trailing summary) passes none, and everything is decoded at
--- `finish` — correct, but held in memory, which is what `max_buffer` bounds. Exceeding it is an
--- error rather than a truncation: a short file that reads as a complete one is the bug this
--- release exists to remove.
---@param opts { decode: fun(text: string, opts: table): dblens.ResultSet, boundary: (fun(text: string): integer)?, columns: string[]?, max_buffer: integer }
---@return dblens.RowReader
function M.reader(opts)
  assert(type(opts.decode) == 'function', 'protocol.reader: needs a decoder')
  assert(
    opts.boundary == nil or type(opts.boundary) == 'function',
    'protocol.reader: boundary must be a function'
  )
  assert(
    type(opts.max_buffer) == 'number' and opts.max_buffer > 0,
    'protocol.reader: needs a positive buffer cap'
  )
  local boundary = opts.boundary
  local columns = opts.columns and vim.deepcopy(opts.columns) or {}
  local seen_header, malformed = false, 0
  -- Two shapes, because the two modes hold different things: `tail` is the incomplete record a
  -- framed reader carries to the next chunk, `parts` is the whole output an unframed one keeps.
  local tail, parts, held = '', {}, 0

  local function take(text)
    local decoded = opts.decode(text, { header = not seen_header, columns = columns })
    seen_header = true
    if #decoded.columns > 0 then
      columns = decoded.columns
    end
    malformed = malformed + decoded.malformed
    return decoded.rows
  end

  local function too_big()
    return ('the result outgrew the %d byte buffer before a whole record arrived'):format(
      opts.max_buffer
    )
  end

  return {
    push = function(chunk)
      assert(type(chunk) == 'string', 'protocol.reader: expected a chunk')
      if not boundary then
        parts[#parts + 1] = chunk
        held = held + #chunk
        if held > opts.max_buffer then
          return nil, too_big()
        end
        return {}, nil
      end
      tail = tail .. chunk
      local cut = boundary(tail)
      assert(cut >= 0 and cut <= #tail, 'protocol.reader: boundary landed outside the buffer')
      if cut == 0 then
        if #tail > opts.max_buffer then
          return nil, too_big()
        end
        return {}, nil
      end
      local whole = tail:sub(1, cut)
      tail = tail:sub(cut + 1)
      return take(whole), nil
    end,
    finish = function()
      local text = boundary and tail or table.concat(parts)
      tail, parts, held = '', {}, 0
      if text == '' then
        return {}, nil
      end
      return take(text), nil
    end,
    columns = function()
      return columns
    end,
    malformed = function()
      return malformed
    end,
  }
end

--- Read one RFC 4180 field starting at `from`.
---
--- Quoting is what carries the meaning here: psql quotes a value only when it contains a comma,
--- a quote or a newline, and prints the NULL marker bare. So a QUOTED field is always literal
--- text, and only an unquoted field can be NULL.
---@return string field, integer next, boolean quoted, boolean row_end
local function read_csv_field(text, from)
  if text:sub(from, from) ~= '"' then
    local at = text:find('[,\n]', from)
    if not at then
      return text:sub(from), #text + 1, false, true
    end
    local row_end = text:sub(at, at) == '\n'
    local last = at - 1
    -- CRLF: the CR belongs to the record terminator, not to the value.
    if row_end and text:sub(last, last) == '\r' then
      last = last - 1
    end
    return text:sub(from, last), at + 1, false, row_end
  end

  local parts, i = {}, from + 1
  while i <= #text do
    local at = text:find('"', i, true)
    if not at then
      -- Unterminated quote: keep what there is rather than dropping the row.
      parts[#parts + 1] = text:sub(i)
      return table.concat(parts), #text + 1, true, true
    end
    parts[#parts + 1] = text:sub(i, at - 1)
    if text:sub(at + 1, at + 1) == '"' then
      parts[#parts + 1] = '"'
      i = at + 2
    else
      local after = text:sub(at + 1, at + 1)
      if after == '\r' and text:sub(at + 2, at + 2) == '\n' then
        return table.concat(parts), at + 3, true, true
      end
      return table.concat(parts), at + 2, true, after ~= ','
    end
  end
  return table.concat(parts), #text + 1, true, true
end

--- Split CSV text into records of fields, marking which fields were quoted.
---@return { values: string[], quoted: boolean[] }[]
local function split_csv(text)
  local records, from = {}, 1
  while from <= #text do
    local values, quoted = {}, {}
    while true do
      local field, next_at, was_quoted, ended = read_csv_field(text, from)
      values[#values + 1] = field
      quoted[#quoted + 1] = was_quoted
      from = next_at
      if ended then
        break
      end
    end
    -- A trailing newline ends the last record; it is not an extra empty one.
    if #values > 1 or values[1] ~= '' or from <= #text then
      records[#records + 1] = { values = values, quoted = quoted }
    end
  end
  return records
end

--- Decode RFC 4180 CSV, as psql emits it under `--csv`.
---
--- `exec` reads client output as raw bytes (`text = false`), so on Windows every record ends
--- `\r\n`. `read_csv_field` drops that CR as the framing it is, and only there: a CR inside a
--- QUOTED value is data and survives.
---@param stdout string
---@param opts { header: boolean?, null_sentinel: string?, columns: string[]? }?
---@return dblens.ResultSet
function M.decode_csv(stdout, opts)
  assert(type(stdout) == 'string', 'protocol.decode_csv: expected string')
  opts = opts or {}
  local null_sentinel = opts.null_sentinel or M.NULL_SENTINEL

  local records = split_csv(stdout)
  local columns = opts.columns and vim.deepcopy(opts.columns) or {}
  -- `header = false` is what a streamed read passes for every chunk after the first: the header
  -- came in the one before it, and taking a data row for a header would drop it.
  if opts.header ~= false and #records > 0 then
    columns = records[1].values
    table.remove(records, 1)
  end

  local rows, malformed = {}, 0
  for _, record in ipairs(records) do
    local fields = {}
    for i, value in ipairs(record.values) do
      fields[i] = (not record.quoted[i] and value == null_sentinel) and M.NULL or value
    end
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
