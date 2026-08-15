--- Serialising result sets: yank formats, and file export.
---
--- Export is STREAMED and never silently partial. Rows are appended page by page to a temp file
--- beside the target and renamed into place only once the whole run succeeded, so a cancelled or
--- failed export cannot leave a half-written file where a complete one used to be, and the caller
--- is always told how many rows landed and whether a cap stopped them.
---
--- Where the rows come from is the caller's business: `stream` is handed a `fetch` function, so
--- this module knows nothing about sessions, gates or paging.
local mutate = require('dblens.mutate')
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

--- One CSV record of exactly `count` fields, so a short row still lines up with the header.
---@param values any[]
---@param count integer
---@return string
local function csv_line(values, count)
  local fields = {}
  for i = 1, count do
    fields[i] = csv_field(values[i])
  end
  return table.concat(fields, ',')
end

--- One row as a name -> value object. SQL NULL becomes JSON null via `vim.NIL`.
local function json_object(row, columns)
  local object = {}
  for i, name in ipairs(columns) do
    object[name] = row[i] == nil and protocol.NULL or row[i]
  end
  return object
end

---@param result dblens.ResultSet
---@param opts { header: boolean? }?
---@return string
function M.to_csv(result, opts)
  assert(type(result) == 'table' and result.rows, 'export.to_csv: expected a result set')
  opts = opts or {}
  local lines = {}
  if opts.header ~= false then
    lines[#lines + 1] = csv_line(result.columns, #result.columns)
  end
  for _, row in ipairs(result.rows) do
    lines[#lines + 1] = csv_line(row, #result.columns)
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
    out[#out + 1] = json_object(row, result.columns)
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

-- ---------------------------------------------------------------------------
-- file formats

--- Streaming encoders, one per format. Each appends straight to the open file, so an export of
--- a million rows never has to exist in memory.
---
--- `finish(note)` takes the warning the run wants recorded. Only `sql` has a comment syntax to
--- put it in; for `csv` and `json` the notification is the only channel, which is why the caller
--- must never treat a written file as proof the run was complete.
---@type table<string, fun(file: file*, opts: table): { chunk: fun(columns: string[], rows: any[][]), finish: fun(note: string?) }>
local ENCODERS = {}

ENCODERS.csv = function(file)
  local wrote_header = false
  return {
    chunk = function(columns, rows)
      if not wrote_header then
        file:write(csv_line(columns, #columns), '\n')
        wrote_header = true
      end
      for _, row in ipairs(rows) do
        file:write(csv_line(row, #columns), '\n')
      end
    end,
    finish = function() end,
  }
end

ENCODERS.json = function(file)
  local wrote_any = false
  file:write('[')
  return {
    chunk = function(columns, rows)
      for _, row in ipairs(rows) do
        file:write(wrote_any and ',\n  ' or '\n  ')
        file:write(vim.json.encode(json_object(row, columns)))
        wrote_any = true
      end
    end,
    finish = function()
      file:write(wrote_any and '\n]\n' or ']\n')
    end,
  }
end

ENCODERS.sql = function(file, opts)
  assert(opts.relation and opts.dialect, 'export: the sql encoder needs a relation and a dialect')
  return {
    chunk = function(columns, rows)
      for _, row in ipairs(rows) do
        file:write(mutate.insert_text(opts.relation, columns, row, opts.dialect), '\n')
      end
    end,
    finish = function(note)
      if note then
        file:write('-- ', note, '\n')
      end
    end,
  }
end

M.FORMATS = { 'csv', 'json', 'sql' }

--- The format a path asks for.
---
--- Guessed, but never guessed WRONG in silence: an extension that names no known format is an
--- error, because writing a `.tsv` as CSV without saying so is the same class of quiet lie the
--- truncated export was.
---@param path string
---@return string? format, string? error
function M.format_for(path)
  assert(type(path) == 'string', 'export.format_for: expected a path')
  local extension = path:lower():match('%.([%w]+)$')
  if extension and ENCODERS[extension] then
    return extension, nil
  end
  return nil,
    ('cannot tell the export format from `%s` - end the name with .%s'):format(
      path,
      table.concat(M.FORMATS, ', .')
    )
end

-- ---------------------------------------------------------------------------
-- the writer

---@class dblens.ExportWriter
local Writer = {}
Writer.__index = Writer

--- Append rows. The first chunk's columns are the ones every later chunk is written against.
---@param columns string[]
---@param rows any[][]
function Writer:chunk(columns, rows)
  assert(self.file, 'export writer: already closed')
  assert(vim.islist(columns) and vim.islist(rows), 'export writer: expected columns and rows')
  if not self.columns then
    self.columns = columns
  end
  self.encoder.chunk(self.columns, rows)
end

--- Close the file and move it into place.
---@param note string?  -- a warning to record in the file, where the format can carry one
---@return boolean ok, string? error
function Writer:finish(note)
  assert(self.file, 'export writer: already closed')
  self.encoder.finish(note)
  -- Writes are buffered, so `close` is where a full disk or a bad handle actually surfaces.
  local closed, close_err = self.file:close()
  self.file = nil
  if not closed then
    os.remove(self.temp)
    return false, ('could not write %s: %s'):format(self.target, tostring(close_err))
  end
  local renamed, rename_err = os.rename(self.temp, self.target)
  if not renamed then
    os.remove(self.temp)
    return false, ('could not replace %s: %s'):format(self.target, tostring(rename_err))
  end
  return true, nil
end

--- Give up, leaving whatever was already at the target untouched.
function Writer:abort()
  if self.file then
    self.file:close()
    self.file = nil
  end
  os.remove(self.temp)
end

--- Open an export for writing.
---@param path string
---@param format string
---@param opts { relation: dblens.Relation?, dialect: dblens.Dialect? }?
---@return dblens.ExportWriter? writer, string? error
function M.open(path, format, opts)
  opts = opts or {}
  local encoder = ENCODERS[format]
  if not encoder then
    return nil,
      ('unknown export format `%s` (%s)'):format(tostring(format), table.concat(M.FORMATS, ', '))
  end
  if format == 'sql' and not (opts.relation and opts.dialect) then
    return nil, 'the .sql format writes INSERTs, so it needs a table - export a browsed table'
  end
  -- `vim.fn.expand` would run backticks in the path through the shell.
  local expanded, path_err = require('dblens.path').expand(path)
  if not expanded then
    return nil, path_err
  end
  local dir = vim.fn.fnamemodify(expanded, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    return nil, ('directory does not exist: %s'):format(dir)
  end
  -- Temp file in the same directory, so the rename into place is atomic.
  local temp = ('%s.dblens-%d.tmp'):format(expanded, vim.uv.os_getpid())
  local file, err = io.open(temp, 'w')
  if not file then
    return nil, ('could not write %s: %s'):format(expanded, err)
  end
  return setmetatable({
    file = file,
    temp = temp,
    target = expanded,
    columns = nil,
    encoder = encoder(file, opts),
  }, Writer),
    nil
end

--- Write a result set that is already in memory.
---@param result dblens.ResultSet
---@param path string
---@param format string
---@param opts { relation: dblens.Relation?, dialect: dblens.Dialect?, note: string? }?
---@return boolean ok, string? error
function M.write(result, path, format, opts)
  assert(type(result) == 'table' and result.rows, 'export.write: expected a result set')
  opts = opts or {}
  local writer, err = M.open(path, format, opts)
  if not writer then
    return false, err
  end
  writer:chunk(result.columns, result.rows)
  return writer:finish(opts.note)
end

-- ---------------------------------------------------------------------------
-- the streamed export

---@class dblens.ExportPlan
---@field path string
---@field format string
---@field max_rows integer  -- hard cap; hitting it stops the run and is reported, never hidden
---@field batch integer     -- rows per fetch
---@field relation dblens.Relation?
---@field dialect dblens.Dialect?
---@field fetch fun(offset: integer, limit: integer, on_done: fun(result: dblens.ResultSet?, err: string?))

--- Export by repeatedly fetching a window of rows until the source runs out or the cap stops it.
---
--- The run is finished exactly once: every exit path either renames the file into place or aborts
--- it, and `on_done` is called with a summary or with the error that stopped it.
---@param plan dblens.ExportPlan
---@param on_done fun(summary: { rows: integer, capped: boolean, path: string }?, err: string?)
function M.stream(plan, on_done)
  assert(type(plan.fetch) == 'function', 'export.stream: needs a fetch function')
  assert(type(on_done) == 'function', 'export.stream: on_done must be a function')
  assert(
    type(plan.max_rows) == 'number' and plan.max_rows >= 1,
    'export.stream: max_rows must be positive'
  )
  assert(type(plan.batch) == 'number' and plan.batch >= 1, 'export.stream: batch must be positive')

  local writer, open_err = M.open(plan.path, plan.format, plan)
  if not writer then
    on_done(nil, open_err)
    return
  end

  local written, offset = 0, 0

  local function close(capped)
    local note = capped
        and ('dblens stopped at the %d row export cap - this file is NOT the whole result'):format(
          plan.max_rows
        )
      or nil
    local ok, finish_err = writer:finish(note)
    if not ok then
      on_done(nil, finish_err)
      return
    end
    on_done({ rows = written, capped = capped, path = writer.target }, nil)
  end

  local function fail(err)
    writer:abort()
    on_done(nil, err)
  end

  --- Reaching the cap on a FULL page leaves it unknown whether anything is left, and the
  --- difference decides between a clean report and a loud one. One row settles it.
  local function probe_for_more()
    plan.fetch(offset, 1, function(result, err)
      if err then
        fail(err)
        return
      end
      close(#result.rows > 0)
    end)
  end

  local function step()
    local want = math.min(plan.batch, plan.max_rows - written)
    assert(want >= 1, 'export.stream: a step must ask for at least one row')
    plan.fetch(offset, want, function(result, fetch_err)
      if fetch_err then
        fail(fetch_err)
        return
      end
      assert(type(result) == 'table' and vim.islist(result.rows), 'export.stream: bad fetch result')
      writer:chunk(result.columns, result.rows)
      written = written + #result.rows
      offset = offset + #result.rows
      -- A short page is the evidence the source is exhausted.
      if #result.rows < want then
        close(false)
        return
      end
      if written < plan.max_rows then
        step()
        return
      end
      probe_for_more()
    end)
  end
  step()
end

return M
