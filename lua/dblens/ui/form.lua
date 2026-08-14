--- Adding and removing saved connections.
---
--- Fields come from the adapter, so a new adapter gets a working form with no changes here. The
--- form never asks for a password: it asks where the password comes from.
local adapters = require('dblens.adapters')
local connections = require('dblens.connections')

local M = {}

local SECRET_CHOICES = {
  { label = 'no password (sqlite, socket or .pgpass auth)', kind = 'none' },
  { label = 'from an environment variable', kind = 'env' },
  { label = 'from a command (e.g. pass, 1password)', kind = 'cmd' },
}

--- Ask for each adapter field in turn, then the secret reference.
local function ask_fields(spec, adapter, index, on_done)
  local field = adapter.fields[index]
  if not field then
    on_done(spec)
    return
  end
  local prompt = ('%s%s: '):format(field.label, field.required and ' (required)' or '')
  vim.ui.input(
    { prompt = prompt, default = field.default and tostring(field.default) or '' },
    function(input)
      if input == nil then
        return
      end
      local value = vim.trim(input)
      if value == '' and field.required then
        vim.notify(('dblens: %s is required'):format(field.label), vim.log.levels.ERROR)
        return
      end
      if value ~= '' then
        spec[field.name] = type(field.default) == 'number' and (tonumber(value) or value) or value
      end
      ask_fields(spec, adapter, index + 1, on_done)
    end
  )
end

local function ask_secret(spec, on_done)
  local labels = {}
  for index, choice in ipairs(SECRET_CHOICES) do
    labels[index] = choice.label
  end
  vim.ui.select(labels, { prompt = 'Password source' }, function(_, index)
    if not index then
      return
    end
    local kind = SECRET_CHOICES[index].kind
    if kind == 'none' then
      on_done(spec)
      return
    end
    local prompt = kind == 'env' and 'Environment variable name: ' or 'Command (with arguments): '
    vim.ui.input({ prompt = prompt }, function(input)
      if input == nil or vim.trim(input) == '' then
        return
      end
      if kind == 'env' then
        spec.password_env = vim.trim(input)
      else
        spec.password_cmd = vim.split(vim.trim(input), '%s+')
      end
      on_done(spec)
    end)
  end)
end

--- Interactively add a connection to the connections file.
---@param options table
---@param on_done fun(spec: dblens.ConnectionSpec)?
function M.add(options, on_done)
  vim.ui.select(adapters.kinds(), { prompt = 'Database kind' }, function(kind)
    if not kind then
      return
    end
    local adapter = adapters.get(kind)
    vim.ui.input({ prompt = 'Connection name: ' }, function(name)
      if not name or vim.trim(name) == '' then
        return
      end
      local spec = { name = vim.trim(name), kind = kind }
      ask_fields(spec, adapter, 1, function(filled)
        ask_secret(filled, function(complete)
          vim.ui.select({ 'read-write', 'read-only' }, { prompt = 'Access' }, function(access)
            if not access then
              return
            end
            complete.read_only = access == 'read-only'
            M.persist(options, complete, on_done)
          end)
        end)
      end)
    end)
  end)
end

--- Validate and append a spec to the connections file.
function M.persist(options, spec, on_done)
  local problem = connections.validate(vim.tbl_extend('force', spec, { source = 'file' }))
  if problem then
    vim.notify('dblens: ' .. problem, vim.log.levels.ERROR)
    return
  end
  -- Saving rewrites the whole file, so a file we could not parse must not be overwritten.
  local existing, _, file_error = connections.load(options)
  if file_error then
    vim.notify(('dblens: refusing to write - %s'):format(file_error), vim.log.levels.ERROR)
    return
  end
  for _, other in ipairs(existing) do
    if other.name == spec.name then
      vim.notify(
        ('dblens: a connection named `%s` already exists'):format(spec.name),
        vim.log.levels.ERROR
      )
      return
    end
  end
  spec.source = 'file'
  existing[#existing + 1] = spec
  local ok, err = connections.save(options, existing)
  if not ok then
    vim.notify('dblens: ' .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(('dblens: saved connection `%s`'):format(spec.name))
  if on_done then
    on_done(spec)
  end
end

--- Remove a saved connection by name. Connections declared in `setup{}` cannot be removed here.
function M.remove(options, name)
  local specs, _, file_error = connections.load(options)
  if file_error then
    vim.notify(('dblens: refusing to write - %s'):format(file_error), vim.log.levels.ERROR)
    return
  end
  local keep, found = {}, nil
  for _, spec in ipairs(specs) do
    if spec.name == name then
      found = spec
    else
      keep[#keep + 1] = spec
    end
  end
  if not found then
    vim.notify(('dblens: no connection named `%s`'):format(name), vim.log.levels.ERROR)
    return
  end
  if found.source == 'config' then
    vim.notify(
      ('dblens: `%s` comes from setup{} - remove it there'):format(name),
      vim.log.levels.ERROR
    )
    return
  end
  local ok, err = connections.save(options, keep)
  if not ok then
    vim.notify('dblens: ' .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(('dblens: removed connection `%s`'):format(name))
end

return M
