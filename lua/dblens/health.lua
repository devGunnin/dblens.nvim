--- `:checkhealth dblens`.
---
--- Reports what dblens can see: the editor version, each database client, the resolved config and
--- the connection specs. A password reference is reported as present or absent and never
--- resolved, so no secret can reach the health buffer.
local adapters = require('dblens.adapters')
local config = require('dblens.config')

local M = {}

local health = vim.health
local MIN_NVIM = '0.10'

local function first_line(text)
  return vim.trim((tostring(text):gmatch('[^\r\n]*')()) or '')
end

local function check_nvim()
  health.start('Neovim')
  local version = tostring(vim.version())
  if vim.fn.has('nvim-' .. MIN_NVIM) == 1 then
    health.ok('Neovim ' .. version)
  else
    health.error(('Neovim %s is too old; dblens needs %s or newer'):format(version, MIN_NVIM))
  end
end

--- Resolved options, or nil when `setup{}` rejected the user's config.
---@return table?
local function check_config()
  health.start('Configuration')
  local ok, result = pcall(config.get)
  if not ok then
    health.error('configuration is invalid: ' .. tostring(result))
    return nil
  end
  assert(type(result) == 'table', 'health: config.get must return options')
  health.ok('configuration loaded')
  health.info(('connections file: %s'):format(result.connections_file))
  local cap = result.history.max_entries
  health.info(('history file: %s (max %d entries)'):format(result.history_file, cap))
  health.info(('session file: %s'):format(result.state_file))
  return result
end

--- Version string reported by a client binary. Bounded: a hung client must not hang checkhealth.
---@return string? version, string? error
local function client_version(binary)
  local ok, result = pcall(function()
    return vim.system({ binary, '--version' }, { text = true }):wait(2000)
  end)
  if not ok then
    return nil, first_line(result)
  end
  if result.code ~= 0 then
    local reported = first_line(result.stderr or result.stdout or '')
    return nil, ('exit %d: %s'):format(result.code, reported)
  end
  local text = first_line(result.stdout or '')
  if text == '' then
    text = first_line(result.stderr or '')
  end
  if text == '' then
    return nil, 'no output'
  end
  return text, nil
end

--- A missing client is a warning, not an error: most users only ever use one of the three.
local function check_clients(options)
  health.start('Database clients')
  local clients = (options and options.clients) or config.defaults.clients
  assert(type(clients) == 'table', 'health: `clients` must be a table')
  for _, kind in ipairs(adapters.kinds()) do
    local adapter = assert(adapters.get(kind), 'health: a registered kind must resolve')
    local binary = clients[kind]
    if type(binary) ~= 'string' or binary == '' then
      health.error(('%s: no client configured in `clients.%s`'):format(adapter.label, kind))
    elseif vim.fn.executable(binary) ~= 1 then
      local unusable = ('%s connections are unavailable'):format(adapter.label)
      health.warn(('%s: `%s` not executable; %s'):format(adapter.label, binary, unusable))
    else
      local version, err = client_version(binary)
      if version then
        health.ok(('%s: %s -- %s'):format(adapter.label, binary, version))
      else
        health.warn(('%s: `%s` reported no version (%s)'):format(adapter.label, binary, err))
      end
    end
  end
end

--- Whether a password reference is configured -- never which variable, never its value.
local function describe_secret(spec)
  if spec.password_env then
    return 'password from an environment reference'
  end
  if spec.password_cmd then
    return 'password from a command reference'
  end
  return 'no password reference'
end

local function count_sources(specs)
  local by_source = {}
  for _, spec in ipairs(specs) do
    by_source[spec.source] = (by_source[spec.source] or 0) + 1
  end
  return by_source
end

local function check_connections(options)
  health.start('Connections')
  if not options then
    health.warn('skipped: the configuration could not be loaded')
    return
  end
  local ok, specs, problems = pcall(require('dblens.connections').load, options)
  if not ok then
    health.error('could not load connections: ' .. tostring(specs))
    return
  end
  assert(vim.islist(specs) and vim.islist(problems), 'health: expected specs and problems')
  for _, problem in ipairs(problems) do
    health.error(problem)
  end
  if #specs == 0 then
    health.info('no connections defined')
    return
  end
  local by_source = count_sources(specs)
  local from_config, from_file = by_source.config or 0, by_source.file or 0
  local counts = ('%d from setup{}, %d from file'):format(from_config, from_file)
  health.ok(('%d connection(s): %s'):format(#specs, counts))
  for _, spec in ipairs(specs) do
    local access = spec.read_only and 'read-only' or 'writable'
    health.info(('%s [%s] %s, %s'):format(spec.name, spec.kind, access, describe_secret(spec)))
  end
end

local INTEGRATIONS = {
  { label = 'nvim-web-devicons', module = 'nvim-web-devicons' },
  { label = 'nvim-cmp', module = 'cmp' },
  { label = 'blink.cmp', module = 'blink.cmp' },
}

--- Presence without loading: a health check must not run another plugin's setup as a side effect.
local function module_present(name)
  if package.loaded[name] then
    return true
  end
  local path = 'lua/' .. name:gsub('%.', '/')
  return #vim.api.nvim_get_runtime_file(path .. '.lua', false) > 0
    or #vim.api.nvim_get_runtime_file(path .. '/init.lua', false) > 0
end

local function check_integrations()
  health.start('Optional integrations')
  for _, integration in ipairs(INTEGRATIONS) do
    if module_present(integration.module) then
      health.ok(integration.label .. ': available')
    else
      health.info(integration.label .. ': not installed (optional)')
    end
  end
end

function M.check()
  check_nvim()
  local options = check_config()
  check_clients(options)
  check_connections(options)
  check_integrations()
end

return M
