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

--- The options in force, and WHERE THEY CAME FROM.
---
--- `config.get()` falls back to defaults, so reporting it as "loaded" told a user whose `setup{}`
--- had just been refused that their configuration was fine while nothing they set was in effect.
--- `config.status()` is what distinguishes the three cases.
---@param options table  -- the options actually in force
local function check_config(options)
  assert(type(options) == 'table', 'health: check_config needs the resolved options')
  health.start('Configuration')
  local state, rejected = config.status()
  local in_force = state == 'configured' and 'the last setup{} that succeeded'
    or 'the built-in defaults'
  if rejected then
    health.error(('setup{} was refused, so %s are in force: %s'):format(in_force, rejected))
  elseif state == 'defaults' then
    health.info('setup{} has not run; these are the built-in defaults')
  else
    health.ok('configuration loaded')
  end
  health.info(('dblens %s'):format(require('dblens').VERSION))
  health.info(('connections file: %s'):format(options.connections_file))
  local cap = options.history.max_entries
  health.info(('history file: %s (max %d entries)'):format(options.history_file, cap))
  health.info(('session file: %s'):format(options.state_file))
  -- The limits a bug report needs: a truncated grid or a killed client is one of these four.
  health.info(
    ('limits: page_size %d, max_rows %d, max_bytes %d, timeout_ms %d'):format(
      options.page_size,
      options.max_rows,
      options.max_bytes,
      options.timeout_ms
    )
  )
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

--- A missing client is a warning, not an error: most users only ever use one of the six.
local function check_clients(options)
  health.start('Database clients')
  local clients = options.clients
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

--- What a LOCKED connection means PER ENGINE. Reported as a warning where it is best-effort,
--- because the word "read-only" reads the same in the UI for all of them and is not the same
--- promise: on SQL Server the refusal is dblens's own classifier, not the engine.
---
--- The STRENGTH is in the line, not only in the ok/warn colour, so a copied `:checkhealth` report
--- still says which engines are guaranteed and which are best-effort.
local function check_read_only()
  health.start('Read-only enforcement')
  for _, kind in ipairs(adapters.kinds()) do
    local adapter = assert(adapters.get(kind), 'health: a registered kind must resolve')
    local enforcement = adapter.read_only_enforcement
    local line = ('%s [%s, %s]: %s'):format(
      adapter.label,
      enforcement.strength,
      enforcement.mechanism,
      enforcement.summary
    )
    if enforcement.strength == 'strong' then
      health.ok(line)
    else
      health.warn(line)
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
  local best_effort = {}
  for _, spec in ipairs(specs) do
    local adapter = adapters.get(spec.kind)
    local strength = adapter and adapter.read_only_enforcement.strength or 'unknown'
    -- The strength rides on the connection's own line: "read-only" reads the same for all of
    -- them, and on SQL Server it is a classifier rather than the engine.
    local access = spec.read_only and ('read-only (%s)'):format(strength) or 'writable'
    health.info(('%s [%s] %s, %s'):format(spec.name, spec.kind, access, describe_secret(spec)))
    if spec.read_only and strength ~= 'strong' then
      best_effort[#best_effort + 1] = spec.name
    end
  end
  -- Named per connection rather than per engine: the user reads their own connection here, and a
  -- locked one whose lock is a client-side blocklist should not look like the guaranteed ones.
  if #best_effort > 0 then
    health.warn(
      ("locked but only best-effort: %s -- the lock is dblens's verb classifier, a blocklist "):format(
        table.concat(best_effort, ', ')
      )
        .. 'that cannot be proven complete against every administrative statement. Connect as a '
        .. 'read-only database login for a boundary the server enforces (:h dblens-safety-mssql)'
    )
  end
  -- Surfaced where a user reviews their connections, because "read-only" above reads stronger
  -- than it is: it stops every ordinary write, not a deliberate dblink/UDF one.
  health.info(
    'a strong read-only connection is enforced by the engine per run, and is not a boundary '
      .. 'against a user with write credentials -- connect as a database read-only role for that '
      .. '(:h dblens-safety-guarantee)'
  )
end

--- What dblens binds globally, and what was already bound to the same key by someone else.
---
--- `<leader>d` is the debug prefix in LazyVim, AstroNvim and most kickstart-derived configs, and
--- `vim.keymap.set` overwrites in silence, so the user's `<leader>dc` can become dblens's with
--- nothing on screen to say so. Reported here rather than notified at startup: a plugin that
--- talks on every launch is worse than one a user has to ask.
local function check_keymaps()
  health.start('Global keymaps')
  local taken = require('dblens').keymaps_taken_over()
  if #taken == 0 then
    health.ok('no global keymap was taken over from another plugin')
    return
  end
  for _, entry in ipairs(taken) do
    health.warn(
      ('%s was bound by something else (%s) before dblens took it -- set '):format(
        entry.lhs,
        entry.previous
      ) .. '`keymaps = { global = false }` or remap the action to keep it'
    )
  end
end

local INTEGRATIONS = {
  { label = 'nvim-web-devicons', module = 'nvim-web-devicons' },
  { label = 'nvim-cmp', module = 'cmp' },
  { label = 'blink.cmp', module = 'blink.cmp' },
  { label = 'which-key.nvim', module = 'which-key' },
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

--- The SQL formatter `:DbLensFormat` would use. Reported here rather than left to fail at the
--- keystroke: an external tool that is simply not installed is exactly what checkhealth is for.
local function check_formatter(options)
  health.start('SQL formatter')
  local argv, err = require('dblens.format').detect(options.format.command)
  if not argv then
    health.info(err .. ' (optional; only `:DbLensFormat` needs it)')
    return
  end
  health.ok(('%s: %s'):format(argv[1], table.concat(argv, ' ')))
end

function M.check()
  check_nvim()
  local ok, options = pcall(config.get)
  if not ok then
    health.start('Configuration')
    health.error('the configuration could not be resolved at all: ' .. tostring(options))
    return
  end
  check_config(options)
  check_clients(options)
  check_read_only()
  check_connections(options)
  check_keymaps()
  check_formatter(options)
  check_integrations()
end

return M
