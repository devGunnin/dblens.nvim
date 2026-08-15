--- Serialising result sets: yank formats, and file export.
---
--- Export is STREAMED and never silently partial. Rows are appended to a temp file beside the
--- target as they arrive and renamed into place only once the whole run succeeded, so a cancelled
--- or failed export cannot leave a half-written file where a complete one used to be, and the
--- caller is always told how many rows landed and whether a cap stopped them.
---
--- Where the rows come from is the caller's business: `stream` is handed a `run` function, so this
--- module knows nothing about sessions or gates. What it does require of that function is the
--- property the file's honesty rests on — the rows are ONE query's, so the file is one snapshot
--- of the table rather than a stitch of several reads of a table that may be changing.
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
--- `finish(note)` takes the warning the run wants recorded and returns whether it could record it.
--- Only `sql` has a comment syntax to put it in; a `csv` or `json` file gets a marker written
--- beside it instead, because the notification is transient and the file outlives it.
---@type table<string, fun(file: file*, opts: table): { chunk: fun(columns: string[], rows: any[][]), finish: fun(note: string?): boolean }>
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
    -- A trailing `#` line is not CSV, and a reader that ignored it would still be short a row.
    finish = function()
      return false
    end,
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
      return false
    end,
  }
end

ENCODERS.sql = function(file, opts)
  assert(opts.relation and opts.dialect, 'export: the sql encoder needs a relation and a dialect')
  -- mysql and mariadb read `\` inside a literal as an escape unless NO_BACKSLASH_ESCAPES is set,
  -- so the same file replays differently under the two modes. Say which one it was written for.
  if opts.dialect.backslash_escape then
    file:write(
      '-- dblens: backslashes are escaped for the default SQL mode; replaying this under\n',
      '-- NO_BACKSLASH_ESCAPES would double every one of them.\n'
    )
  end
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
      return true
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

--- Where an incomplete file that cannot hold a comment says so, since it outlives the notification
--- that said it first.
---@param target string
---@return string
function M.marker_for(target)
  assert(type(target) == 'string' and target ~= '', 'export.marker_for: needs a target path')
  return target .. '.INCOMPLETE'
end

--- Record — or clear — the marker beside a file the format itself could not annotate.
---@param target string
---@param note string?  -- nil once the run is known complete
---@return boolean ok, string? error
local function write_marker(target, note)
  local path = M.marker_for(target)
  if not note then
    -- A marker left by an earlier capped run would lie about the file that just replaced it.
    if not vim.uv.fs_stat(path) then
      return true, nil
    end
    local removed, remove_err = os.remove(path)
    if not removed then
      return false,
        ('%s is complete but the stale %s beside it could not be removed: %s'):format(
          target,
          path,
          tostring(remove_err)
        )
    end
    return true, nil
  end
  local file, open_err = io.open(path, 'w')
  if not file then
    return false,
      ('%s was written but is INCOMPLETE, and that could not be recorded in %s: %s'):format(
        target,
        path,
        tostring(open_err)
      )
  end
  file:write(note, '\n')
  local closed, close_err = file:close()
  if not closed then
    return false,
      ('%s was written but is INCOMPLETE, and that could not be recorded in %s: %s'):format(
        target,
        path,
        tostring(close_err)
      )
  end
  return true, nil
end

--- Close the file and move it into place.
---@param note string?  -- a warning to record, in the file or in a marker beside it
---@return boolean ok, string? error
function Writer:finish(note)
  assert(self.file, 'export writer: already closed')
  local carried = self.encoder.finish(note) == true
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
  return write_marker(self.target, not carried and note or nil)
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
---@field relation dblens.Relation?
---@field dialect dblens.Dialect?
---@field run fun(sink: fun(columns: string[], rows: any[][]): string?, on_done: fun(err: string?))

--- Export the rows of ONE query, written to the file as they arrive.
---
--- `run` must ask its source for at most `max_rows + 1` rows: the extra row never reaches the
--- file, it is the evidence that the cap — and not the table — decided where the file stopped.
--- Asking one query for that is what makes the answer trustworthy; asking a second query "is
--- there more?" would be answering it about a table that may have changed in between.
---
--- The run is finished exactly once: every exit path either renames the file into place or aborts
--- it, and `on_done` is called with a summary or with the error that stopped it.
---@param plan dblens.ExportPlan
---@param on_done fun(summary: { rows: integer, capped: boolean, path: string }?, err: string?)
function M.stream(plan, on_done)
  assert(type(plan.run) == 'function', 'export.stream: needs a run function')
  assert(type(on_done) == 'function', 'export.stream: on_done must be a function')
  assert(
    type(plan.max_rows) == 'number' and plan.max_rows >= 1,
    'export.stream: max_rows must be positive'
  )

  local writer, open_err = M.open(plan.path, plan.format, plan)
  if not writer then
    on_done(nil, open_err)
    return
  end

  local written, capped = 0, false

  --- Take a batch of rows, up to the cap. Returns a message when the run must stop.
  local function sink(columns, rows)
    assert(vim.islist(columns) and vim.islist(rows), 'export.stream: expected columns and rows')
    local room = plan.max_rows - written
    assert(room >= 0, 'export.stream: wrote past the cap')
    if #rows > room then
      capped = true
      rows = vim.list_slice(rows, 1, room)
    end
    writer:chunk(columns, rows)
    written = written + #rows
    return nil
  end

  plan.run(sink, function(err)
    if err then
      writer:abort()
      on_done(nil, err)
      return
    end
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
  end)
end

return M
