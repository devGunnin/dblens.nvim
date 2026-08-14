--- Renders a result set into buffer lines plus highlight marks. Pure: builds text, touches no
--- buffer. The results window owns applying the marks, in chunks.
---
--- Layout is a fixed-width column grid:
---
---     ` id │ name        │ total `
---     `────┼─────────────┼───────`
---     `  1 │ Ada         │ 99.99 `
---
--- Column display widths are uniform down the buffer, so a cell can be located from the cursor's
--- display column without storing per-row geometry.
local protocol = require('dblens.protocol')

local M = {}

local CONTROL = { ['\n'] = '↵', ['\t'] = '⇥', ['\r'] = '␍' }

--- Replace control bytes with visible stand-ins so one cell always occupies one line.
local function sanitize(text)
  if not text:find('[%z\1-\31\127]') then
    return text
  end
  return (text:gsub('[%z\1-\31\127]', function(char)
    return CONTROL[char] or '·'
  end))
end

--- Display width, skipping the vim call for plain ASCII (the overwhelmingly common case).
local function width_of(text)
  if not text:find('[^\32-\126]') then
    return #text
  end
  return vim.fn.strdisplaywidth(text)
end

local UTF8_CHAR = '[%z\1-\127\194-\244][\128-\191]*'

--- Cut to at most `width` display cells.
local function truncate_display(text, width)
  if width <= 0 then
    return ''
  end
  if not text:find('[^\32-\126]') then
    return text:sub(1, width)
  end
  -- No UTF-8 char exceeds 4 bytes, so this byte slice is a safe superset of the cut.
  local slice = text:sub(1, width * 4 + 4)
  local out, used = {}, 0
  for char in slice:gmatch(UTF8_CHAR) do
    local w = vim.fn.strdisplaywidth(char)
    if used + w > width then
      break
    end
    out[#out + 1] = char
    used = used + w
  end
  return table.concat(out)
end

local function type_class(declared)
  local lowered = declared:lower()
  if lowered:find('bool') then
    return 'boolean'
  end
  for _, needle in ipairs({ 'int', 'real', 'floa', 'doub', 'num', 'dec', 'money', 'serial' }) do
    if lowered:find(needle, 1, true) then
      return 'number'
    end
  end
  return 'text'
end

--- Classify a cell for highlighting and alignment. Declared types win; content sniffing is the
--- fallback for ad-hoc query results, where no type is known.
local function classify(cell, declared)
  if cell == protocol.NULL or cell == nil then
    return 'null'
  end
  if declared and declared ~= '' then
    return type_class(declared)
  end
  if tonumber(cell) ~= nil and cell:find('%S') then
    return 'number'
  end
  local lowered = cell:lower()
  if lowered == 'true' or lowered == 'false' then
    return 'boolean'
  end
  return 'text'
end

local CLASS_HL = { null = 'DbLensNull', number = 'DbLensNumber', boolean = 'DbLensBoolean' }

---@class dblens.GridInput
---@field columns string[]
---@field rows any[][]
---@field types string[]?     -- declared column types when the source is a known relation
---@field max_col_width integer
---@field null_display string
---@field separator string
---@field truncation string
---@field sort { column: string, desc: boolean }?
---@field dirty table<string, boolean>?  -- keys `row .. ':' .. col`, marking queued edits

---@class dblens.GridOutput
---@field lines string[]
---@field marks { line: integer, col: integer, end_col: integer, hl: string }[]
---@field spans { from: integer, to: integer }[]  -- 1-based display columns per data column
---@field widths integer[]
---@field header_lines integer

--- Precompute display text and class for every cell, and the resulting column widths.
local function measure(input)
  local widths, texts, classes = {}, {}, {}
  for index, name in ipairs(input.columns) do
    widths[index] = math.min(math.max(width_of(name), 1), input.max_col_width)
  end
  for r, row in ipairs(input.rows) do
    texts[r], classes[r] = {}, {}
    for c = 1, #input.columns do
      local class = classify(row[c], input.types and input.types[c])
      local raw = class == 'null' and input.null_display or sanitize(tostring(row[c]))
      texts[r][c], classes[r][c] = raw, class
      widths[c] = math.min(math.max(widths[c], width_of(raw)), input.max_col_width)
    end
  end
  return widths, texts, classes
end

--- Pad or truncate to exactly `width` display cells.
local function fit(text, width, align, truncation)
  local w = width_of(text)
  if w > width then
    text = truncate_display(text, width - width_of(truncation)) .. truncation
    w = width_of(text)
  end
  local pad = string.rep(' ', math.max(0, width - w))
  return align == 'right' and (pad .. text) or (text .. pad)
end

--- Join fitted cells into one line, recording each cell's byte range for marking.
---@return string line, { from: integer, to: integer }[] byte ranges, 0-based
local function compose(cells, separator)
  local parts, ranges, bytes = { ' ' }, {}, 1
  for index, cell in ipairs(cells) do
    if index > 1 then
      local sep = ' ' .. separator .. ' '
      parts[#parts + 1] = sep
      bytes = bytes + #sep
    end
    ranges[index] = { from = bytes, to = bytes + #cell }
    parts[#parts + 1] = cell
    bytes = bytes + #cell
  end
  parts[#parts + 1] = ' '
  return table.concat(parts), ranges
end

--- Render a result set.
---@param input dblens.GridInput
---@return dblens.GridOutput
function M.render(input)
  assert(vim.islist(input.columns), 'grid.render: columns must be a list')
  assert(vim.islist(input.rows), 'grid.render: rows must be a list')
  assert(input.max_col_width >= 4, 'grid.render: max_col_width must be at least 4')

  if #input.columns == 0 then
    return { lines = {}, marks = {}, spans = {}, widths = {}, header_lines = 0 }
  end

  local widths, texts, classes = measure(input)
  local lines, marks = {}, {}

  local heads = {}
  for index, name in ipairs(input.columns) do
    heads[index] = fit(name, widths[index], 'left', input.truncation)
  end
  local header, head_ranges = compose(heads, input.separator)
  lines[1] = header
  marks[#marks + 1] = { line = 0, col = 0, end_col = #header, hl = 'DbLensHeader' }
  if input.sort then
    local at = protocol.column_index(input.columns, input.sort.column)
    if at then
      marks[#marks + 1] =
        { line = 0, col = head_ranges[at].from, end_col = head_ranges[at].to, hl = 'DbLensSortKey' }
    end
  end

  local segments = {}
  for index, width in ipairs(widths) do
    segments[index] = string.rep('─', width + 2)
  end
  lines[2] = table.concat(segments, '┼')
  marks[#marks + 1] = { line = 1, col = 0, end_col = #lines[2], hl = 'DbLensRule' }

  local spans, at = {}, 2
  for index, width in ipairs(widths) do
    spans[index] = { from = at, to = at + width - 1 }
    at = at + width + 3
  end

  local dirty = input.dirty or {}
  for r = 1, #input.rows do
    local cells = {}
    for c = 1, #input.columns do
      cells[c] = fit(
        texts[r][c],
        widths[c],
        classes[r][c] == 'number' and 'right' or 'left',
        input.truncation
      )
    end
    local line, ranges = compose(cells, input.separator)
    local index = #lines + 1
    lines[index] = line
    for c = 1, #input.columns do
      local hl = dirty[r .. ':' .. c] and 'DbLensDirty' or CLASS_HL[classes[r][c]]
      if hl then
        marks[#marks + 1] =
          { line = index - 1, col = ranges[c].from, end_col = ranges[c].to, hl = hl }
      end
    end
  end

  return { lines = lines, marks = marks, spans = spans, widths = widths, header_lines = 2 }
end

--- Which data column contains a display column, or nil when between columns.
---@param spans { from: integer, to: integer }[]
---@param display_col integer  -- 1-based, as from `virtcol`
---@return integer?
function M.column_at(spans, display_col)
  for index, span in ipairs(spans) do
    if display_col >= span.from and display_col <= span.to then
      return index
    end
  end
  return nil
end

--- Nearest data column at or before a display column, for a cursor resting on a separator.
---@return integer?
function M.nearest_column(spans, display_col)
  local found = M.column_at(spans, display_col)
  if found then
    return found
  end
  for index = #spans, 1, -1 do
    if display_col >= spans[index].from then
      return index
    end
  end
  return #spans > 0 and 1 or nil
end

return M
