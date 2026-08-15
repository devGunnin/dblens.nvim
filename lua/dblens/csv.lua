--- Reading CSV, to RFC 4180.
---
--- This is a BOUNDARY: the text comes from a file the user pointed at, so every value it returns
--- is untrusted, and a malformed file is an error naming the line rather than a best guess at what
--- was meant. Nothing here builds SQL — `dblens.import` does that, and it quotes.
---
--- Quoting carries one meaning beyond framing: an UNQUOTED empty field is SQL NULL, a quoted one
--- (`""`) is the empty string. That is exactly what dblens's own CSV export writes, so a table
--- exported and imported back keeps NULL and `''` apart.
local protocol = require('dblens.protocol')

local M = {}

local BOM = '\239\187\191'

--- Read one quoted field, starting at the opening quote.
---@return string? value, integer? next_index, string? error
local function quoted_field(text, at, line)
  local parts = {}
  local index = at + 1
  while index <= #text do
    local char = text:sub(index, index)
    if char ~= '"' then
      parts[#parts + 1] = char
      index = index + 1
    elseif text:sub(index + 1, index + 1) == '"' then
      -- A doubled quote is one quote of data, not the end of the field.
      parts[#parts + 1] = '"'
      index = index + 2
    else
      local after = text:sub(index + 1, index + 1)
      if after ~= '' and after ~= ',' and after ~= '\n' and after ~= '\r' then
        return nil, nil, ('line %d: unexpected text after a quoted value'):format(line)
      end
      return table.concat(parts), index + 1, nil
    end
  end
  return nil, nil, ('line %d: a quoted value is never closed'):format(line)
end

--- Read one unquoted field, up to the next comma or line end.
---@return any value, integer next_index, string? error
local function plain_field(text, at, line)
  local stop = text:find('[,\r\n]', at) or (#text + 1)
  local raw = text:sub(at, stop - 1)
  if raw:find('"', 1, true) then
    return nil, at, ('line %d: a quote inside an unquoted value'):format(line)
  end
  -- Unquoted and empty is the one place quoting decides the VALUE: this is SQL NULL.
  return raw == '' and protocol.NULL or raw, stop, nil
end

--- Parse CSV text into records.
---
--- Every record is returned as it was written — no blank line is skipped and no short row is
--- padded, because a row that does not match the header is the caller's error to report against
--- the table it is importing into, not something to repair here.
---@param text string
---@param opts { max_rows: integer? }?  -- records, header included; exceeding it is an error
---@return any[][]? rows, string? error  -- each field is a string or protocol.NULL
function M.parse(text, opts)
  assert(type(text) == 'string', 'csv.parse: expected the file text')
  opts = opts or {}
  local max_rows = opts.max_rows
  assert(max_rows == nil or max_rows >= 1, 'csv.parse: max_rows must be positive')

  local at = text:sub(1, 3) == BOM and 4 or 1
  local rows, row, line = {}, {}, 1

  --- Close the record being read. Returns an error when the file is longer than allowed.
  local function end_record()
    rows[#rows + 1] = row
    row = {}
    if max_rows and #rows > max_rows then
      return ('the file has more than %d rows'):format(max_rows)
    end
    return nil
  end

  while at <= #text do
    local value, next_at, err
    if text:sub(at, at) == '"' then
      value, next_at, err = quoted_field(text, at, line)
    else
      value, next_at, err = plain_field(text, at, line)
    end
    if err then
      return nil, err
    end
    -- Refused HERE, at the file boundary: no client can carry a NUL in a statement, and further
    -- down the only thing left to stop it was an assertion, which is a traceback rather than a
    -- message. `line` is still the line the value opened on.
    if type(value) == 'string' and value:find('%z') then
      return nil, ('line %d: a value contains a NUL byte, which SQL cannot carry'):format(line)
    end
    row[#row + 1] = value
    -- A newline INSIDE a quoted value is data, but it still moved the file on a line.
    if type(value) == 'string' then
      local _, breaks = value:gsub('\n', '')
      line = line + breaks
    end

    at = next_at
    local char = text:sub(at, at)
    if char == ',' then
      at = at + 1
    elseif char == '\r' or char == '\n' or char == '' then
      if char == '\r' and text:sub(at + 1, at + 1) == '\n' then
        at = at + 2
      elseif char ~= '' then
        at = at + 1
      end
      line = line + 1
      local problem = end_record()
      if problem then
        return nil, problem
      end
    end
  end

  -- A file whose last line has no terminator still ends on a record.
  if #row > 0 then
    local problem = end_record()
    if problem then
      return nil, problem
    end
  end
  return rows, nil
end

return M
