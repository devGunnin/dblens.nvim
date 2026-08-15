--- Connection specs: where they come from, how they are validated, and how their secret is
--- resolved at connect time.
---
--- A password is never a value in a spec. Specs carry a *reference* (`password_env` or
--- `password_cmd`) which is resolved into memory only when a connection is opened, and the
--- resolved value is never written back, logged, or persisted.
local adapters = require('dblens.adapters')
local exec = require('dblens.exec')
local path_mod = require('dblens.path')

local M = {}

---@class dblens.ConnectionSpec
---@field name string
---@field kind string
---@field read_only boolean?
---@field password_env string?    -- environment variable holding the password
---@field password_cmd string[]?  -- argv printing the password on stdout
---@field source 'config'|'file'|'discovered'
--- Assigned on load; 'config' specs are not editable, and 'discovered' ones exist only in memory
--- for the session that found them (see `dblens.discovery`).

--- Keys never allowed in a stored spec, mapped to what to do instead.
local FORBIDDEN = {
  password = 'use `password_env` or `password_cmd` instead of storing the password',
  pass = 'use `password_env` or `password_cmd` instead of storing the password',
  pwd = 'use `password_env` or `password_cmd` instead of storing the password',
}

--- Check the shape of a `password_cmd`.
---
--- This is argv, not a shell line and not a path: it is run with `vim.system`, so nothing in it
--- is ever evaluated. It IS a program the user asked dblens to run at connect time, which is the
--- one place the connections file is trusted rather than defended against — `path.lua` exists
--- because `vim.fn.expand` would evaluate a path nobody meant as a command, while this field is
--- a command by definition. All that can be checked here is that it is a runnable argv.
---@param spec table
---@return string? error
local function validate_password_cmd(spec)
  if not vim.islist(spec.password_cmd) or #spec.password_cmd == 0 then
    return ('connection `%s`: `password_cmd` must be a non-empty list of arguments'):format(
      spec.name
    )
  end
  for index, argument in ipairs(spec.password_cmd) do
    if type(argument) ~= 'string' or argument == '' then
      return ('connection `%s`: `password_cmd` argument %d must be a non-empty string'):format(
        spec.name,
        index
      )
    end
    if argument:find('[%z\n\r]') then
      return ('connection `%s`: `password_cmd` argument %d must be a single line'):format(
        spec.name,
        index
      )
    end
  end
  return nil
end

--- Why `name` cannot be an environment variable name, or nil.
---
--- The mistake this exists for: `password_env = ".env"`. A `.env` FILE is discovery's input, not a
--- variable, and stored as one it produced `$.env is not set` on every start.
---@param name any
---@return string? problem
function M.env_name_problem(name)
  if type(name) ~= 'string' or name == '' then
    return 'the environment variable name is empty'
  end
  if name:find('[/\\]') or name:sub(1, 1) == '.' then
    return ('`%s` is a file name, not an environment variable: dblens reads a `.env` FILE '):format(
      name
    ) .. 'through :DbLensDiscover; `password_env` wants the VARIABLE name, e.g. PGPASSWORD'
  end
  if not name:find('^[%a_][%w_]*$') then
    return ('`%s` is not an environment variable name: give the NAME of the variable holding '):format(
      name
    ) .. 'the password (dblens never stores the password itself)'
  end
  return nil
end

--- Split a `host:port` value typed into a single field.
---
--- Only the unambiguous shape: one colon before a port number. A bare IPv6 literal carries two or
--- more colons and a libpq socket directory carries none, so neither is mistaken for this.
---@param value any
---@return string? host, integer? port  -- nil when the value is not `host:port`
function M.split_host_port(value)
  if type(value) ~= 'string' then
    return nil, nil
  end
  local host, port = value:match('^([^:]+):(%d+)$')
  local number = tonumber(port)
  if not host or not number or number < 1 or number > 65535 then
    return nil, nil
  end
  return host, number
end

--- Validate one spec.
---@param spec table
---@return string? error
function M.validate(spec)
  if type(spec) ~= 'table' then
    return 'connection must be a table'
  end
  if type(spec.name) ~= 'string' or vim.trim(spec.name) == '' then
    return 'connection needs a non-empty `name`'
  end
  for key, advice in pairs(FORBIDDEN) do
    if spec[key] ~= nil then
      return ('connection `%s` must not store a plaintext `%s`: %s'):format(spec.name, key, advice)
    end
  end
  if spec.password_cmd ~= nil then
    local cmd_error = validate_password_cmd(spec)
    if cmd_error then
      return cmd_error
    end
  end
  if spec.password_env ~= nil and type(spec.password_env) ~= 'string' then
    return ('connection `%s`: `password_env` must be a variable name'):format(spec.name)
  end
  local adapter, err = adapters.get(spec.kind)
  if not adapter then
    return ('connection `%s`: %s'):format(spec.name, err)
  end
  return adapter.validate(spec)
end

local function read_json_file(path)
  local file = io.open(path, 'r')
  if not file then
    return nil, nil
  end
  local text = file:read('*a')
  file:close()
  if vim.trim(text) == '' then
    return {}, nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return nil, ('%s is not valid JSON: %s'):format(path, decoded)
  end
  if not vim.islist(decoded) then
    return nil, ('%s must contain a JSON array of connections'):format(path)
  end
  return decoded, nil
end

---@class dblens.ConnectionEntry
---@field spec dblens.ConnectionSpec  -- as configured or stored; usable only when `problem` is nil
---@field source 'config'|'file'
---@field problem string?  -- why this entry cannot be used at all

--- Every configured and stored connection, the unusable ones included.
---
--- `load` drops what it cannot validate, which is how a bad hand-edit became invisible: it could
--- not be listed, connected or removed, and only announced itself as an error on every start. The
--- manager needs those entries, so they are reported here with the reason instead of dropped.
---
--- Duplicate names are a problem on the SECOND entry, so the first one stays usable — `:DbLens`
--- can never open a different database than the one the name suggests.
---@param options table  resolved config
---@return dblens.ConnectionEntry[] entries, string? file_error
function M.entries(options)
  assert(type(options) == 'table', 'connections.entries: expected resolved options')
  local entries, seen = {}, {}

  local function accept(raw, source)
    if type(raw) ~= 'table' then
      local problem = ('%s connection %d is not an object'):format(source, #entries + 1)
      entries[#entries + 1] = { spec = { source = source }, source = source, problem = problem }
      return
    end
    local spec = vim.deepcopy(raw)
    spec.source = source
    local problem = M.validate(spec)
    if not problem and seen[spec.name] then
      problem = ('duplicate connection name `%s` (%s and %s)'):format(
        spec.name,
        seen[spec.name],
        source
      )
    end
    if not problem then
      if spec.read_only == nil then
        spec.read_only = options.safety.read_only_default
      end
      -- Normalised here so every reader agrees. The connections file is hand-editable JSON, and a
      -- truthy non-boolean used to read as "read-only" in the UI while enforcement saw `~= true`.
      spec.read_only = spec.read_only ~= false
      seen[spec.name] = source
    end
    entries[#entries + 1] = { spec = spec, source = source, problem = problem }
  end

  for _, spec in ipairs(options.connections) do
    accept(spec, 'config')
  end
  local stored, file_error = read_json_file(options.connections_file)
  for _, spec in ipairs(stored or {}) do
    accept(spec, 'file')
  end
  return entries, file_error
end

--- Load the usable specs from `setup{}` and from the connections file.
---@param options table  resolved config
---@return dblens.ConnectionSpec[] specs, string[] problems, string? file_error
--- `file_error` is set only when the connections file itself could not be read as JSON. Callers
--- that intend to WRITE the file must refuse on it, or they would overwrite unreadable content.
function M.load(options)
  local entries, file_error = M.entries(options)
  local specs, problems = {}, {}
  if file_error then
    problems[#problems + 1] = file_error
  end
  for _, entry in ipairs(entries) do
    if entry.problem then
      problems[#problems + 1] = entry.problem
    else
      specs[#specs + 1] = entry.spec
    end
  end
  return specs, problems, file_error
end

--- Write the stored list.
---
--- Refuses to author a plaintext password: an entry holding one is already on disk, but rewriting
--- the file around it would make dblens itself the thing that wrote it, which it never is.
---@param options table
---@param list table[]  -- entries exactly as they are to appear in the file
---@return boolean ok, string? error
local function write_stored(options, list)
  assert(vim.islist(list), 'connections.write_stored: expected a list of entries')
  for _, entry in ipairs(list) do
    for key, advice in pairs(FORBIDDEN) do
      if type(entry) == 'table' and entry[key] ~= nil then
        return false,
          ('%s holds a plaintext `%s` for `%s` — remove it in the file first: %s'):format(
            options.connections_file,
            key,
            tostring(entry.name),
            advice
          )
      end
    end
  end

  local path = options.connections_file
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, 'p') == 0 then
    return false, ('could not create %s'):format(dir)
  end
  local file, open_err = io.open(path, 'w')
  if not file then
    return false, ('could not write %s: %s'):format(path, open_err)
  end
  file:write(vim.json.encode(list))
  file:close()
  -- Specs are not secret, but they name hosts and users; keep them owner-only.
  pcall(vim.fn.setfperm, path, 'rw-------')
  return true, nil
end

--- Add, replace or delete ONE stored connection, keyed by the name it is stored under.
---
--- Keyed by name over the file's RAW entries, so an entry `load` refuses can still be fixed or
--- deleted — that entry is exactly the one the user has to get at. Every other stored entry is
--- written back as the user wrote it.
---
--- A WHITELIST, not a blacklist: only a spec the caller means to STORE is accepted. A
--- config-sourced spec belongs to the user's `setup{}` call, and a DISCOVERED one exists only for
--- the session that found it — writing one would persist a connection whose password was never
--- stored and cannot be resolved again.
---@param options table
---@param name string   -- the stored entry to replace or delete; appended when it is not there
---@param spec dblens.ConnectionSpec?  -- nil deletes
---@return boolean ok, string? error
function M.put(options, name, spec)
  assert(type(name) == 'string' and name ~= '', 'connections.put: needs the stored name')
  assert(spec == nil or type(spec) == 'table', 'connections.put: spec must be a table or nil')
  if spec and spec.source ~= nil and spec.source ~= 'file' then
    return false,
      ('connection `%s` is %s, not a saved connection: it is never written to disk'):format(
        tostring(spec.name),
        spec.source
      )
  end

  local stored, file_error = read_json_file(options.connections_file)
  if file_error then
    return false, file_error
  end
  stored = stored or {}

  local entry = nil
  if spec then
    entry = vim.deepcopy(spec)
    entry.source = nil
    local problem = M.validate(vim.tbl_extend('force', entry, { source = 'file' }))
    if problem then
      return false, problem
    end
    for _, other in ipairs(stored) do
      if type(other) == 'table' and other.name == entry.name and other.name ~= name then
        return false, ('a connection named `%s` already exists'):format(entry.name)
      end
    end
  end

  local list, found = {}, false
  for _, other in ipairs(stored) do
    if type(other) == 'table' and other.name == name then
      found = true
      if entry then
        list[#list + 1] = entry
      end
    else
      list[#list + 1] = other
    end
  end
  if not found then
    if not entry then
      return false, ('no saved connection named `%s`'):format(name)
    end
    list[#list + 1] = entry
  end
  return write_stored(options, list)
end

--- Resolve a spec's password.
---
--- Calls back with `(secret|nil, err|nil)`. A spec with no reference resolves to nil, which is
--- correct for sqlite and for clients relying on ambient auth (.pgpass, peer, socket).
---@param spec dblens.ConnectionSpec
---@param options table
---@param on_done fun(secret: string?, err: string?)
function M.resolve_secret(spec, options, on_done)
  assert(type(on_done) == 'function', 'connections.resolve_secret: on_done must be a function')

  if spec.password_env then
    local value = vim.env[spec.password_env]
    if value == nil or value == '' then
      on_done(nil, ('connection `%s`: $%s is not set'):format(spec.name, spec.password_env))
      return
    end
    on_done(value, nil)
    return
  end

  if not spec.password_cmd then
    on_done(nil, nil)
    return
  end

  exec.run({
    argv = spec.password_cmd,
    timeout_ms = math.min(options.timeout_ms, 15000),
    max_bytes = 64 * 1024,
  }, function(result)
    if not result.ok then
      -- Report the command's failure, never its output: that output is the secret.
      on_done(
        nil,
        ('connection `%s`: password command failed (%s)'):format(
          spec.name,
          result.reason or ('exit ' .. result.code)
        )
      )
      return
    end
    local secret = result.stdout:gmatch('[^\r\n]*')()
    if not secret or secret == '' then
      on_done(nil, ('connection `%s`: password command printed nothing'):format(spec.name))
      return
    end
    on_done(secret, nil)
  end)
end

---@class dblens.ConnectionHealth
---@field state 'ok'|'broken'|'unknown'
---@field reason string?  -- why it is broken, or what is deferred; nil when it is fine

local OK = { state = 'ok' }

--- Whether a connection could be opened right now, without opening it.
---
--- Reference resolution only, and only the side-effect-free half of it: an environment variable is
--- read, a `password_cmd` is NOT run — running one at list time would fire a pinentry (or anything
--- else the user put there) just for drawing a row. That one reports as `unknown` and is proved on
--- connect. Nothing here talks to a database, and nothing here raises: a broken connection is a
--- flag in the manager, never an error on every start.
---@param spec dblens.ConnectionSpec
---@param problem string?  -- the entry's validation problem, when the caller already has it
---@return dblens.ConnectionHealth
function M.health(spec, problem)
  assert(type(spec) == 'table', 'connections.health: expected a spec')
  local invalid = problem or M.validate(spec)
  if invalid then
    return { state = 'broken', reason = invalid }
  end

  local adapter = adapters.get(spec.kind)
  local host, port = M.split_host_port(spec.host)
  if host and adapter and adapter.fields then
    for _, field in ipairs(adapter.fields) do
      if field.name == 'port' then
        return {
          state = 'broken',
          reason = ('host `%s` has the port in it: host `%s`, port %d'):format(
            spec.host,
            host,
            port
          ),
        }
      end
    end
  end

  if spec.password_env then
    local named = M.env_name_problem(spec.password_env)
    if named then
      return { state = 'broken', reason = named }
    end
    local value = vim.env[spec.password_env]
    if value == nil or value == '' then
      return { state = 'broken', reason = ('$%s is not set'):format(spec.password_env) }
    end
  end

  if adapter and adapter.file and not spec.create then
    local file = path_mod.expand(spec.path)
    if file and vim.fn.filereadable(file) == 0 then
      return { state = 'broken', reason = ('no such database file: %s'):format(spec.path) }
    end
  end

  if spec.password_cmd then
    return { state = 'unknown', reason = 'password comes from a command, checked on connect' }
  end
  return OK
end

--- Find a spec by name.
---@return dblens.ConnectionSpec?
function M.find(specs, name)
  for _, spec in ipairs(specs) do
    if spec.name == name then
      return spec
    end
  end
  return nil
end

return M
