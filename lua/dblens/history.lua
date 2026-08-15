--- Query history and saved snippets, persisted together in one JSON file.
---
--- History is the user's own record of what they ran, so nothing here discards it quietly: an
--- unreadable or malformed file is an error, never an empty store. The store is passed in and
--- owned by the caller; this module keeps no state of its own.
local M = {}

---@class dblens.HistoryEntry
---@field connection string
---@field sql string
---@field at integer  -- os.time() when it was recorded

---@class dblens.Snippet
---@field name string
---@field sql string

---@class dblens.HistoryStore
---@field history dblens.HistoryEntry[]  -- oldest first
---@field snippets dblens.Snippet[]
---@field max_entries integer  -- cap, taken from `options.history.max_entries` at load time

local function positive_int(value)
  return type(value) == 'number' and value == math.floor(value) and value >= 1
end

local function assert_store(store, where)
  assert(
    type(store) == 'table' and vim.islist(store.history) and vim.islist(store.snippets),
    where .. ': expected a history store'
  )
end

local function entry_cap(options)
  assert(type(options) == 'table', 'dblens.history: expected resolved options')
  assert(
    type(options.history_file) == 'string' and options.history_file ~= '',
    'dblens.history: `history_file` must be resolved before use'
  )
  local max = type(options.history) == 'table' and options.history.max_entries or nil
  assert(positive_int(max), 'dblens.history: `history.max_entries` must be a positive integer')
  return max
end

--- Read the file's bytes. An absent file yields nil with no error; an unreadable one is an error.
local function read_file(path)
  if not vim.uv.fs_stat(path) then
    return nil, nil
  end
  local file, open_err = io.open(path, 'r')
  if not file then
    return nil, ('could not read %s: %s'):format(path, open_err)
  end
  local text = file:read('*a')
  file:close()
  if text == nil then
    return nil, ('could not read %s'):format(path)
  end
  return text, nil
end

--- A decoded field that must be a JSON array. Missing is fine; any other shape is an error.
local function as_list(value, path, field)
  if value == nil then
    return {}, nil
  end
  if type(value) ~= 'table' or not vim.islist(value) then
    return nil, ('%s: `%s` must be a JSON array'):format(path, field)
  end
  return value, nil
end

local function valid_entry(entry)
  if type(entry) ~= 'table' then
    return false
  end
  return type(entry.connection) == 'string' and type(entry.sql) == 'string'
end

local function parse_history(list, path)
  local out = {}
  for i, entry in ipairs(list) do
    if not valid_entry(entry) then
      return nil, ('%s: history entry %d needs a string `connection` and `sql`'):format(path, i)
    end
    out[i] = {
      connection = entry.connection,
      sql = entry.sql,
      at = type(entry.at) == 'number' and math.floor(entry.at) or 0,
    }
  end
  return out, nil
end

local function parse_snippets(list, path)
  local out = {}
  for i, snippet in ipairs(list) do
    local named = type(snippet) == 'table' and type(snippet.name) == 'string' and snippet.name ~= ''
    if not named or type(snippet.sql) ~= 'string' then
      return nil, ('%s: snippet %d needs a non-empty `name` and a `sql` string'):format(path, i)
    end
    out[i] = { name = snippet.name, sql = snippet.sql }
  end
  return out, nil
end

--- Load the store. A missing file is an empty store; a corrupt one is an error.
---@param options table  resolved config
---@return dblens.HistoryStore? store, string? error
function M.load(options)
  local max = entry_cap(options)
  local path = options.history_file
  local text, read_err = read_file(path)
  if read_err then
    return nil, read_err
  end
  if text == nil or vim.trim(text) == '' then
    return { history = {}, snippets = {}, max_entries = max }, nil
  end

  local decoded_ok, decoded = pcall(vim.json.decode, text)
  if not decoded_ok then
    return nil, ('%s is not valid JSON: %s'):format(path, decoded)
  end
  local shaped = type(decoded) == 'table' and not (vim.islist(decoded) and next(decoded) ~= nil)
  if not shaped then
    return nil, ('%s must contain a JSON object with `history` and `snippets`'):format(path)
  end

  local history_list, history_err = as_list(decoded.history, path, 'history')
  if not history_list then
    return nil, history_err
  end
  local snippet_list, snippet_err = as_list(decoded.snippets, path, 'snippets')
  if not snippet_list then
    return nil, snippet_err
  end
  local history, entry_err = parse_history(history_list, path)
  if not history then
    return nil, entry_err
  end
  local snippets, parse_err = parse_snippets(snippet_list, path)
  if not snippets then
    return nil, parse_err
  end
  return { history = history, snippets = snippets, max_entries = max }, nil
end

--- Newest entry index for one connection, or nil when it has none.
local function last_index_for(history, connection_name)
  for i = #history, 1, -1 do
    if history[i].connection == connection_name then
      return i
    end
  end
  return nil
end

--- Record one executed statement. Blank SQL is ignored, and re-running the statement that is
--- already newest for that connection moves it rather than duplicating it.
---@param store dblens.HistoryStore
---@param connection_name string
---@param sql string
---@return boolean recorded  false when the statement was blank
function M.record(store, connection_name, sql)
  assert_store(store, 'history.record')
  assert(positive_int(store.max_entries), 'history.record: store carries no entry cap')
  assert(
    type(connection_name) == 'string' and connection_name ~= '',
    'history.record: needs a connection name'
  )
  assert(type(sql) == 'string', 'history.record: sql must be a string')

  local text = vim.trim(sql)
  if text == '' then
    return false
  end
  local previous = last_index_for(store.history, connection_name)
  if previous and store.history[previous].sql == text then
    table.remove(store.history, previous)
  end
  store.history[#store.history + 1] = { connection = connection_name, sql = text, at = os.time() }
  while #store.history > store.max_entries do
    table.remove(store.history, 1)
  end
  return true
end

--- Recorded statements, newest first. Entries are shared with the store: treat them read-only.
---@param store dblens.HistoryStore
---@param connection_name string?  nil for every connection
---@return dblens.HistoryEntry[]
function M.entries(store, connection_name)
  assert_store(store, 'history.entries')
  assert(
    connection_name == nil or type(connection_name) == 'string',
    'history.entries: connection name must be a string'
  )
  local out = {}
  for i = #store.history, 1, -1 do
    local entry = store.history[i]
    if connection_name == nil or entry.connection == connection_name then
      out[#out + 1] = entry
    end
  end
  return out
end

--- Write `text` owner-only, failing loudly rather than leaving a half-written file behind.
local function write_private(path, text)
  local file, open_err = io.open(path, 'w')
  if not file then
    return false, ('could not write %s: %s'):format(path, open_err)
  end
  local written, write_err = file:write(text)
  file:close()
  if not written then
    os.remove(path)
    return false, ('could not write %s: %s'):format(path, tostring(write_err))
  end
  -- Query text can carry anything the user typed; keep the file unreadable to other accounts.
  if vim.fn.setfperm(path, 'rw-------') == 0 then
    os.remove(path)
    return false, ('could not restrict permissions on %s'):format(path)
  end
  return true, nil
end

--- Persist the store, replacing the file atomically.
---@param store dblens.HistoryStore
---@param options table  resolved config
---@return boolean ok, string? error
function M.save(store, options)
  assert_store(store, 'history.save')
  assert(
    type(options) == 'table' and type(options.history_file) == 'string',
    'history.save: `history_file` must be resolved before use'
  )

  local path = options.history_file
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, 'p') == 0 then
    return false, ('could not create %s'):format(dir)
  end
  -- Temp file in the same directory, so the rename is atomic: a crash cannot truncate history.
  local temp = ('%s.%d.tmp'):format(path, vim.uv.os_getpid())
  local payload = vim.json.encode({ history = store.history, snippets = store.snippets })
  local ok, write_err = write_private(temp, payload)
  if not ok then
    return false, write_err
  end
  local renamed, rename_err = os.rename(temp, path)
  if not renamed then
    os.remove(temp)
    return false, ('could not replace %s: %s'):format(path, tostring(rename_err))
  end
  return true, nil
end

local function find_snippet(snippets, name)
  for i, snippet in ipairs(snippets) do
    if snippet.name == name then
      return i
    end
  end
  return nil
end

--- Save a named snippet, replacing any snippet already under that name.
---@param store dblens.HistoryStore
---@param name string
---@param sql string
---@return boolean ok, string? error
function M.save_snippet(store, name, sql)
  assert_store(store, 'history.save_snippet')
  if type(name) ~= 'string' or vim.trim(name) == '' then
    return false, 'snippet needs a non-empty name'
  end
  local key = vim.trim(name)
  if type(sql) ~= 'string' or vim.trim(sql) == '' then
    return false, ('snippet `%s` needs a non-empty statement'):format(key)
  end
  local at = find_snippet(store.snippets, key)
  store.snippets[at or (#store.snippets + 1)] = { name = key, sql = vim.trim(sql) }
  return true, nil
end

--- Saved snippets, sorted by name. The copy is the caller's to keep.
---@param store dblens.HistoryStore
---@return dblens.Snippet[]
function M.snippets(store)
  assert_store(store, 'history.snippets')
  local out = vim.deepcopy(store.snippets)
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

---@param store dblens.HistoryStore
---@param name string
---@return boolean ok, string? error
function M.delete_snippet(store, name)
  assert_store(store, 'history.delete_snippet')
  if type(name) ~= 'string' or name == '' then
    return false, 'snippet needs a name'
  end
  local at = find_snippet(store.snippets, name)
  if not at then
    return false, ('no snippet named `%s`'):format(name)
  end
  table.remove(store.snippets, at)
  return true, nil
end

return M
