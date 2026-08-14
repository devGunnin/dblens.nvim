--- Serialising result sets: yank formats and file export. Pure formatting plus one file write.
local protocol = require('dblens.protocol')

local M = {}

--- RFC 4180: quote when the value contains a delimiter, quote or newline; double inner quotes.
local function csv_field(cell)
  if cell == protocol.NULL or cell == nil then
    return ''
  end
  local text = tostring(cell)
  if text:find('[",\r\n]') then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

---@param result dblens.ResultSet
---@param opts { header: boolean? }?
---@return string
function M.to_csv(result, opts)
  assert(type(result) == 'table' and result.rows, 'export.to_csv: expected a result set')
  opts = opts or {}
  local lines = {}
  if opts.header ~= false then
    local head = {}
    for i, name in ipairs(result.columns) do
      head[i] = csv_field(name)
    end
    lines[#lines + 1] = table.concat(head, ',')
  end
  for _, row in ipairs(result.rows) do
    local fields = {}
    for i = 1, #result.columns do
      fields[i] = csv_field(row[i])
    end
    lines[#lines + 1] = table.concat(fields, ',')
  end
  return table.concat(lines, '\n')
end

--- Array of objects. SQL NULL becomes JSON null via `vim.NIL`.
---@param result dblens.ResultSet
---@return string
function M.to_json(result)
  assert(type(result) == 'table' and result.rows, 'export.to_json: expected a result set')
  local out = {}
  for _, row in ipairs(result.rows) do
    local object = {}
    for i, name in ipairs(result.columns) do
      object[name] = row[i] == nil and protocol.NULL or row[i]
    end
    out[#out + 1] = object
  end
  -- An empty array encodes as `{}` unless it is marked, which would be wrong for a row list.
  if #out == 0 then
    return '[]'
  end
  return vim.json.encode(out)
end

--- One row as an aligned `column: value` block, for the row detail popup and row yanking.
---@return string[]
function M.row_lines(columns, row)
  assert(vim.islist(columns), 'export.row_lines: expected a column list')
  local width = 0
  for _, name in ipairs(columns) do
    width = math.max(width, vim.fn.strdisplaywidth(name))
  end
  local lines = {}
  for i, name in ipairs(columns) do
    local pad = string.rep(' ', width - vim.fn.strdisplaywidth(name))
    local value = row[i]
    local text = (value == protocol.NULL or value == nil) and 'NULL' or tostring(value)
    -- keep multi-line values readable rather than collapsing them, indented under the name
    local pieces = vim.split(text, '\n', { plain = true })
    lines[#lines + 1] = ('%s%s  %s'):format(name, pad, pieces[1])
    for index = 2, #pieces do
      lines[#lines + 1] = string.rep(' ', width + 2) .. pieces[index]
    end
  end
  return lines
end

local FORMATS = { csv = M.to_csv, json = M.to_json }

--- Write a result set to disk.
---@param result dblens.ResultSet
---@param path string
---@param format 'csv'|'json'
---@return boolean ok, string? error
function M.write(result, path, format)
  local encode = FORMATS[format]
  if not encode then
    return false, ('unknown export format `%s` (csv, json)'):format(tostring(format))
  end
  -- `vim.fn.expand` would run backticks in the path through the shell.
  local expanded, path_err = require('dblens.path').expand(path)
  if not expanded then
    return false, path_err
  end
  local dir = vim.fn.fnamemodify(expanded, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    return false, ('directory does not exist: %s'):format(dir)
  end
  local file, err = io.open(expanded, 'w')
  if not file then
    return false, ('could not write %s: %s'):format(expanded, err)
  end
  file:write(encode(result), '\n')
  file:close()
  return true, nil
end

return M
