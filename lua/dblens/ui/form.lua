--- Adding, editing and removing saved connections.
---
--- Fields come from the adapter, so a new adapter gets a working form with no changes here. The
--- form never asks for a password: it asks where the password comes from, and refuses an answer
--- that is a password or a file rather than a reference.
local adapters = require('dblens.adapters')
local connections = require('dblens.connections')
local state_mod = require('dblens.state')

local M = {}

local SECRET_CHOICES = {
  { label = 'no password (sqlite, socket or .pgpass auth)', kind = 'none' },
  { label = 'the NAME of an environment variable holding it', kind = 'env' },
  { label = 'a command that PRINTS it (pass, 1password, ...)', kind = 'cmd' },
}

--- The access question, read-only first so the default answer is the safe one.
local ACCESS_CHOICES = {
  {
    label = 'read-only (LOCKED - the default, and what you want unless you are editing)',
    ro = true,
  },
  { label = 'read-write (writes allowed, still previewed and confirmed)', ro = false },
}

local function error_notify(message)
  vim.notify('dblens: ' .. message, vim.log.levels.ERROR)
end

--- A `host:port` typed into the host field, split into the two fields it is.
---
--- The exact mistake this exists for: `host = "localhost:5432"` saved beside a port of its own, so
--- the client resolved a host called `localhost:5432` and every connection failed.
---@param spec table  -- mutated in place
---@param adapter dblens.Adapter
---@return string? problem
local function normalize_host(spec, adapter)
  local host, port = connections.split_host_port(spec.host)
  if not host then
    return nil
  end
  local has_port = false
  for _, field in ipairs(adapter.fields) do
    has_port = has_port or field.name == 'port'
  end
  if not has_port then
    return ('%s connections have no port, so `%s` cannot be one'):format(adapter.kind, spec.host)
  end
  if spec.port ~= nil and spec.port ~= port then
    return ('host `%s` and port %s disagree: give the host alone'):format(spec.host, spec.port)
  end
  spec.host, spec.port = host, port
  return nil
end

--- The typed answer, in the type the field holds. A `y`/`n` field must come back as a BOOLEAN:
--- stored as the string `"false"` it is still truthy, which would silently switch it on.
local function typed(value, default)
  if type(default) == 'number' then
    return tonumber(value) or value
  end
  if type(default) == 'boolean' then
    local yes = value:lower()
    return yes == 'y' or yes == 'yes' or yes == 'true' or yes == '1'
  end
  return value
end

--- Ask for each field in turn, then normalise what the answers add up to.
---@param fields table[]  -- the adapter's fields, or the same list carrying current values
local function ask_fields(spec, adapter, fields, index, on_done)
  local field = fields[index]
  if not field then
    local problem = normalize_host(spec, adapter)
    if problem then
      error_notify(problem)
      return
    end
    on_done(spec)
    return
  end
  local prompt = ('%s%s: '):format(field.label, field.required and ' (required)' or '')
  local default = field.default
  vim.ui.input(
    { prompt = prompt, default = default ~= nil and tostring(default) or '' },
    function(input)
      if input == nil then
        return
      end
      local value = vim.trim(input)
      if value == '' and field.required then
        error_notify(('%s is required'):format(field.label))
        return
      end
      if value ~= '' then
        spec[field.name] = typed(value, default)
      end
      ask_fields(spec, adapter, fields, index + 1, on_done)
    end
  )
end

local function ask_secret(spec, on_done)
  local labels = {}
  for index, choice in ipairs(SECRET_CHOICES) do
    labels[index] = choice.label
  end
  vim.ui.select(labels, { prompt = 'Where the password comes from' }, function(_, index)
    if not index then
      return
    end
    local kind = SECRET_CHOICES[index].kind
    if kind == 'none' then
      spec.password_env, spec.password_cmd = nil, nil
      on_done(spec)
      return
    end
    local prompt = kind == 'env' and 'Environment variable NAME: ' or 'Command (with arguments): '
    vim.ui.input({ prompt = prompt }, function(input)
      if input == nil or vim.trim(input) == '' then
        return
      end
      local value = vim.trim(input)
      if kind == 'env' then
        local problem = connections.env_name_problem(value)
        if problem then
          error_notify(problem)
          return
        end
        spec.password_env, spec.password_cmd = value, nil
      else
        spec.password_env, spec.password_cmd = nil, vim.split(value, '%s+')
      end
      on_done(spec)
    end)
  end)
end

--- Ask whether the connection may be written to. Anything but an explicit read-write answer
--- leaves it LOCKED, so a cancelled or unrecognised choice can never open a writable connection.
local function ask_access(spec, on_done)
  local labels = {}
  for index, choice in ipairs(ACCESS_CHOICES) do
    labels[index] = choice.label
  end
  vim.ui.select(labels, { prompt = 'Access' }, function(_, index)
    if not index then
      return
    end
    spec.read_only = ACCESS_CHOICES[index].ro ~= false
    on_done(spec)
  end)
end

--- `sqlite -- SQLite (read-only: strong)`. The strength is in the picker because it is the one
--- thing that differs between engines and cannot be discovered later without reading the docs.
local function describe_kind(kind)
  local adapter = adapters.get(kind)
  if not adapter then
    return kind
  end
  return ('%s -- %s (read-only: %s)'):format(
    kind,
    adapter.label,
    adapter.read_only_enforcement.strength
  )
end

--- Interactively add a connection to the connections file.
---@param options table
---@param on_done fun(spec: dblens.ConnectionSpec)?
function M.add(options, on_done)
  local select_opts = { prompt = 'Database kind', format_item = describe_kind }
  vim.ui.select(adapters.kinds(), select_opts, function(kind)
    if not kind then
      return
    end
    local adapter = adapters.get(kind)
    vim.ui.input({ prompt = 'Connection name: ' }, function(name)
      if not name or vim.trim(name) == '' then
        return
      end
      local spec = { name = vim.trim(name), kind = kind, read_only = true }
      ask_fields(spec, adapter, adapter.fields, 1, function(filled)
        ask_secret(filled, function(complete)
          ask_access(complete, function(final)
            M.persist(options, final, on_done)
          end)
        end)
      end)
    end)
  end)
end

--- Edit a saved connection: the same questions, answered with what it holds today.
---
--- Reachable for an entry `load` refuses as well as a usable one — a connection that cannot be
--- validated is exactly the one that needs fixing.
---@param options table
---@param name string
---@param on_done fun(spec: dblens.ConnectionSpec)?
function M.edit(options, name, on_done)
  local entries, file_error = connections.entries(options)
  if file_error then
    error_notify(('refusing to write - %s'):format(file_error))
    return
  end
  local found
  for _, entry in ipairs(entries) do
    if entry.spec.name == name then
      found = entry
    end
  end
  if not found then
    error_notify(('no connection named `%s`'):format(name))
    return
  end
  if found.source ~= 'file' then
    error_notify(('`%s` comes from setup{} - edit it there'):format(name))
    return
  end

  local current = vim.deepcopy(found.spec)
  local adapter, adapter_err = adapters.get(current.kind)
  if not adapter then
    error_notify(('`%s`: %s - fix `kind` in the connections file'):format(name, adapter_err))
    return
  end
  local spec = { name = current.name, kind = current.kind, create = current.create }
  -- Each field is prefilled with what the connection holds today, so `<CR>` keeps it. An `and/or`
  -- default here would drop a stored `false`.
  local fields = {}
  for index, field in ipairs(adapter.fields) do
    local value = current[field.name]
    if value == nil then
      value = field.default
    end
    fields[index] =
      { name = field.name, label = field.label, required = field.required, default = value }
  end
  ask_fields(spec, adapter, fields, 1, function(filled)
    ask_secret(filled, function(complete)
      ask_access(complete, function(final)
        local ok, err = connections.put(options, name, final)
        if not ok then
          error_notify(err)
          return
        end
        vim.notify(('dblens: saved connection `%s`'):format(final.name))
        if on_done then
          on_done(final)
        end
      end)
    end)
  end)
end

--- Validate and store a new spec.
function M.persist(options, spec, on_done)
  local problem = connections.validate(vim.tbl_extend('force', spec, { source = 'file' }))
  if problem then
    error_notify(problem)
    return
  end
  -- A file we could not parse must not be overwritten, and a name already taken by an entry the
  -- loader REFUSES is still taken: adding over it would silently replace it.
  local existing, file_error = connections.entries(options)
  if file_error then
    error_notify(('refusing to write - %s'):format(file_error))
    return
  end
  for _, other in ipairs(existing) do
    if other.spec.name == spec.name then
      error_notify(('a connection named `%s` already exists'):format(spec.name))
      return
    end
  end
  local ok, err = connections.put(options, spec.name, spec)
  if not ok then
    error_notify(err)
    return
  end
  vim.notify(('dblens: saved connection `%s`'):format(spec.name))
  if on_done then
    on_done(spec)
  end
end

--- Remove a saved connection by name, everywhere it is remembered.
---
--- The file is only half of it: a live session on that connection and a saved session naming it
--- would both bring it back, which is what made a bad connection feel undeletable.
---@param options table
---@param name string
---@param on_done fun()?
function M.remove(options, name, on_done)
  local entries, file_error = connections.entries(options)
  if file_error then
    error_notify(('refusing to write - %s'):format(file_error))
    return
  end
  for _, entry in ipairs(entries) do
    if entry.spec.name == name and entry.source == 'config' then
      error_notify(('`%s` comes from setup{} - remove it there'):format(name))
      return
    end
  end
  local ok, err = connections.put(options, name, nil)
  if not ok then
    error_notify(err)
    return
  end
  state_mod.forget(options, name)
  require('dblens.app').forget_connection(name)
  vim.notify(('dblens: removed connection `%s`'):format(name))
  if on_done then
    on_done()
  end
end

return M
