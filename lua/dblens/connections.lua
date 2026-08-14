--- Connection specs: where they come from, how they are validated, and how their secret is
--- resolved at connect time.
---
--- A password is never a value in a spec. Specs carry a *reference* (`password_env` or
--- `password_cmd`) which is resolved into memory only when a connection is opened, and the
--- resolved value is never written back, logged, or persisted.
local adapters = require('dblens.adapters')
local exec = require('dblens.exec')

local M = {}

---@class dblens.ConnectionSpec
---@field name string
---@field kind string
---@field read_only boolean?
---@field password_env string?    -- environment variable holding the password
---@field password_cmd string[]?  -- argv printing the password on stdout
---@field source 'config'|'file'  -- assigned on load; 'config' specs are not editable

--- Keys never allowed in a stored spec, mapped to what to do instead.
local FORBIDDEN = {
  password = 'use `password_env` or `password_cmd` instead of storing the password',
  pass = 'use `password_env` or `password_cmd` instead of storing the password',
  pwd = 'use `password_env` or `password_cmd` instead of storing the password',
}

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
  if spec.password_cmd ~= nil and not vim.islist(spec.password_cmd) then
    return ('connection `%s`: `password_cmd` must be a list of arguments'):format(spec.name)
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

--- Load specs from `setup{}` and from the connections file.
---
--- Duplicate names are rejected rather than silently shadowed, so `:DbLens` can never open a
--- different database than the one the name suggests.
---@param options table  resolved config
---@return dblens.ConnectionSpec[] specs, string[] problems, string? file_error
--- `file_error` is set only when the connections file itself could not be read as JSON. Callers
--- that intend to WRITE the file must refuse on it, or they would overwrite unreadable content.
function M.load(options)
  local specs, problems, seen = {}, {}, {}

  local function accept(spec, source)
    local copy = vim.deepcopy(spec)
    copy.source = source
    local err = M.validate(copy)
    if err then
      problems[#problems + 1] = err
      return
    end
    if seen[copy.name] then
      problems[#problems + 1] = ('duplicate connection name `%s` (%s and %s)'):format(
        copy.name,
        seen[copy.name],
        source
      )
      return
    end
    if copy.read_only == nil then
      copy.read_only = options.safety.read_only_default
    end
    seen[copy.name] = source
    specs[#specs + 1] = copy
  end

  for _, spec in ipairs(options.connections) do
    accept(spec, 'config')
  end
  local stored, file_error = read_json_file(options.connections_file)
  if file_error then
    problems[#problems + 1] = file_error
  end
  for _, spec in ipairs(stored or {}) do
    accept(spec, 'file')
  end
  return specs, problems, file_error
end

--- Persist the file-sourced specs. Config-sourced specs are owned by the user's `setup{}` call
--- and are deliberately dropped here rather than copied into the file.
---@param options table
---@param specs dblens.ConnectionSpec[]
---@return boolean ok, string? error
function M.save(options, specs)
  local keep = {}
  for _, spec in ipairs(specs) do
    if spec.source ~= 'config' then
      local copy = vim.deepcopy(spec)
      copy.source = nil
      local err = M.validate(vim.tbl_extend('force', copy, { source = 'file' }))
      if err then
        return false, err
      end
      keep[#keep + 1] = copy
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
  file:write(vim.json.encode(keep))
  file:close()
  -- Specs are not secret, but they name hosts and users; keep them owner-only.
  pcall(vim.fn.setfperm, path, 'rw-------')
  return true, nil
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
