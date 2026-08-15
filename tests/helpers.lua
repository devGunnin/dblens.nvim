--- Helpers shared by the specs. `tests/minit.lua` puts `tests/` on `package.path`, so a spec
--- reaches this with `require('helpers')`.
local MiniTest = require('mini.test')

local M = {}

M.eq = MiniTest.expect.equality
M.neq = MiniTest.expect.no_equality
M.expect_error = MiniTest.expect.error
M.expect_no_error = MiniTest.expect.no_error

--- SQL NULL, as `dblens.protocol` represents it in a decoded row.
M.NULL = vim.NIL

M.FIELD_SEP = '\031'
M.RECORD_SEP = '\030'
M.NULL_SENTINEL = '\029'

--- One wire record: fields joined by the field separator.
---@param ... string
---@return string
function M.record(...)
  local fields = { ... }
  assert(select('#', ...) > 0, 'helpers.record: a record has at least one field')
  for i, field in ipairs(fields) do
    assert(type(field) == 'string', ('helpers.record: field %d must be a string'):format(i))
  end
  return table.concat(fields, M.FIELD_SEP)
end

--- Client stdout: records joined by, and terminated with, the record separator -- exactly what
--- psql `-R` and sqlite `-ascii` emit, trailing separator included.
---@param records string[]
---@return string
function M.wire(records)
  assert(type(records) == 'table', 'helpers.wire: expected a list of records')
  if #records == 0 then
    return ''
  end
  return table.concat(records, M.RECORD_SEP) .. M.RECORD_SEP
end

--- The argv entry following `flag`, or nil when the flag is absent.
---@param argv string[]
---@param flag string
---@return string?
function M.flag_value(argv, flag)
  assert(type(argv) == 'table' and #argv > 0, 'helpers.flag_value: argv must be non-empty')
  assert(type(flag) == 'string' and flag ~= '', 'helpers.flag_value: flag must be a string')
  for i, entry in ipairs(argv) do
    if entry == flag then
      return argv[i + 1]
    end
  end
  return nil
end

--- Whether `value` appears in `list`.
---@param list any[]
---@param value any
---@return boolean
function M.has(list, value)
  assert(type(list) == 'table', 'helpers.has: expected a list')
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

--- Every string reachable from `value`, keys included. Depth-capped: the structures under test
--- are small and shallow, and a cycle must fail loudly rather than spin.
---@param value any
---@param out string[]?
---@param depth integer?
---@return string[]
function M.strings(value, out, depth)
  out, depth = out or {}, depth or 0
  assert(depth < 8, 'helpers.strings: structure is deeper than expected (cycle?)')
  if type(value) == 'string' then
    out[#out + 1] = value
  elseif type(value) == 'table' then
    for key, entry in pairs(value) do
      M.strings(key, out, depth + 1)
      M.strings(entry, out, depth + 1)
    end
  end
  return out
end

--- Contents of a file in this checkout, addressed from the repo root.
---
--- The documentation tables are hand-written and the keymap registry is not, so the specs that
--- prove they agree have to read the repo's own files.
---@param relative string
---@return string
function M.repo_file(relative)
  assert(type(relative) == 'string' and relative ~= '', 'helpers.repo_file: expected a path')
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
  local path = root .. '/' .. relative
  local handle = io.open(path, 'r')
  assert(handle, ('helpers.repo_file: cannot read %s'):format(path))
  local text = handle:read('*a')
  handle:close()
  assert(text ~= '', ('helpers.repo_file: %s is empty'):format(path))
  return text
end

--- A freshly loaded copy of `name`, leaving the already-loaded one in place. Lets a spec see a
--- module in its untouched, never-configured state.
---@param name string
---@return table
function M.fresh_module(name)
  assert(type(name) == 'string' and name ~= '', 'helpers.fresh_module: expected a module name')
  local previous = package.loaded[name]
  package.loaded[name] = nil
  local ok, fresh = pcall(require, name)
  package.loaded[name] = previous
  assert(ok, ('helpers.fresh_module: %s failed to load: %s'):format(name, tostring(fresh)))
  return fresh
end

--- Whether `needle` occurs in any string reachable from `value`. Used to prove that a secret
--- never reaches argv.
---@param value any
---@param needle string
---@return boolean
function M.leaks(value, needle)
  assert(type(needle) == 'string' and needle ~= '', 'helpers.leaks: needle must be a string')
  for _, text in ipairs(M.strings(value)) do
    if text:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- A successful, empty client result.
local function blank_result()
  return {
    ok = true,
    code = 0,
    stdout = '',
    stderr = '',
    truncated = false,
    reason = nil,
    elapsed_ms = 1,
  }
end

--- Modules that capture `dblens.exec` or `dblens.session` at require time, so they must be
--- reloaded alongside the double or they would keep calling the real one.
local EXEC_DEPENDENTS = { 'dblens.session', 'dblens.connections', 'dblens.app' }

--- Deliver stdout the way a STREAMING run does: chunk by chunk, with nothing accumulated in the
--- result. A canned `chunks` list drives the framing, so a spec can cut the wire mid-record.
local function feed_stream(spec, result, chunks)
  local pieces = chunks or { result.stdout }
  result.stdout = ''
  for _, chunk in ipairs(pieces) do
    local problem = spec.on_stdout(chunk)
    if problem then
      result.ok = false
      result.reason = 'consumer'
      result.consumer_error = problem
      return
    end
  end
end

local function make_fake_exec(real, respond, calls)
  local fake = setmetatable({}, { __index = real })
  fake.run = function(spec, on_done)
    assert(type(spec.stdin) == 'string' or spec.stdin == nil, 'fake exec: stdin must be a string')
    assert(type(on_done) == 'function', 'fake exec: on_done must be a function')
    local call = { spec = spec, stdin = spec.stdin, argv = spec.argv, cancelled = false }
    calls[#calls + 1] = call
    local canned = respond(call, #calls) or {}
    local pending = canned.pending == true
    local chunks = canned.chunks
    canned.pending, canned.chunks = nil, nil
    local result = vim.tbl_extend('force', blank_result(), canned)
    if spec.on_stdout then
      feed_stream(spec, result, chunks)
    end
    if not pending then
      on_done(result)
      call.done = true
      return {
        cancel = function() end,
        is_done = function()
          return true
        end,
      }
    end
    -- Held open so a spec can close the UI, cancel, or race a second query against it.
    call.resume = function(final)
      call.done = true
      on_done(vim.tbl_extend('force', result, final or {}))
    end
    return {
      cancel = function()
        call.cancelled = true
      end,
      is_done = function()
        return call.done == true
      end,
    }
  end
  return fake
end

--- Run `fn` with `dblens.exec` replaced by a scripted double, so the write path can be driven
--- end to end with no database. `respond(call, index)` returns fields merged over a successful
--- empty result; `pending = true` holds the call open until `call.resume(...)`.
---@param respond fun(call: table, index: integer): table?
---@param fn fun(session_mod: table, calls: table[])
function M.with_fake_exec(respond, fn)
  assert(type(respond) == 'function', 'helpers.with_fake_exec: respond must be a function')
  assert(type(fn) == 'function', 'helpers.with_fake_exec: fn must be a function')
  local real = require('dblens.exec')
  local saved = { ['dblens.exec'] = real }
  for _, name in ipairs(EXEC_DEPENDENTS) do
    saved[name] = package.loaded[name]
    package.loaded[name] = nil
  end
  local calls = {}
  package.loaded['dblens.exec'] = make_fake_exec(real, respond, calls)

  local ok, err = pcall(fn, require('dblens.session'), calls)
  for name, module in pairs(saved) do
    package.loaded[name] = module
  end
  if not ok then
    error(err, 0)
  end
end

--- A connected session over the fake exec, ready to run statements.
---@param session_mod table
---@param spec table?     -- merged over a writable sqlite spec
---@param overrides table?  -- merged over the default options
---@return table
function M.fake_session(session_mod, spec, overrides)
  local options = require('dblens.config').setup(overrides or {})
  local full = vim.tbl_extend(
    'force',
    { name = 'test', kind = 'sqlite', path = '/tmp/dblens-test.db', read_only = false },
    spec or {}
  )
  local session, err = session_mod.new(full, options)
  assert(session, tostring(err))
  session.connected = true
  return session
end

--- The client each adapter drives by default.
M.CLIENTS = {
  sqlite = 'sqlite3',
  postgres = 'psql',
  mysql = 'mysql',
  mariadb = 'mariadb',
  duckdb = 'duckdb',
  mssql = 'sqlcmd',
}

--- A live FILE-backed database (sqlite, duckdb) for the current test: the client to drive, and a
--- scratch path to seed. `DBLENS_TEST_<KIND>_CLIENT` overrides the binary; a missing binary
--- returns nil so the case can note itself as skipped.
---@param kind 'sqlite'|'duckdb'
---@return { client: string, clients: table }?
function M.live_file_client(kind)
  assert(type(kind) == 'string' and kind ~= '', 'helpers.live_file_client: expected a kind')
  local client = vim.env['DBLENS_TEST_' .. kind:upper() .. '_CLIENT'] or M.CLIENTS[kind]
  if not client or vim.fn.executable(client) ~= 1 then
    return nil
  end
  local clients = vim.tbl_extend('force', M.CLIENTS, {})
  clients[kind] = client
  return { client = client, clients = clients }
end

--- A live server, described entirely by environment so the suite stays green without one.
---
--- `DBLENS_TEST_<KIND>_PORT` is what turns a live case on; `_HOST`, `_USER`, `_PASSWORD`, `_DB`
--- and `_CLIENT` fill in the rest.
---@param kind 'postgres'|'mysql'|'mariadb'|'mssql'
---@return { spec: table, secret: string?, clients: table }?
function M.live_target(kind)
  assert(type(kind) == 'string' and kind ~= '', 'helpers.live_target: expected a kind')
  local prefix = 'DBLENS_TEST_' .. kind:upper()
  local port = tonumber(vim.env[prefix .. '_PORT'] or '')
  if not port then
    return nil
  end
  local clients = vim.tbl_extend('force', M.CLIENTS, {})
  clients[kind] = vim.env[prefix .. '_CLIENT'] or M.CLIENTS[kind]
  local spec = {
    name = 'live',
    kind = kind,
    host = vim.env[prefix .. '_HOST'] or '127.0.0.1',
    port = port,
    user = vim.env[prefix .. '_USER'],
    database = vim.env[prefix .. '_DB'] or 'app',
  }
  -- A dev SQL Server presents a self-signed certificate and ODBC Driver 18 verifies it by
  -- default, so a live mssql target has to say it trusts the one it is pointed at.
  if kind == 'mssql' then
    spec.trust_server_certificate = vim.env[prefix .. '_TRUST_CERT'] ~= '0'
  end
  return { spec = spec, secret = vim.env[prefix .. '_PASSWORD'], clients = clients }
end

--- The single value a synchronous callback was handed, or an explicit "never called" marker.
---@return table  -- { called = boolean, [1] = ..., [2] = ... }
function M.capture()
  local box = { called = false }
  box.sink = function(...)
    box.called = true
    box.n = select('#', ...)
    for i = 1, box.n do
      box[i] = (select(i, ...))
    end
  end
  return box
end

return M
