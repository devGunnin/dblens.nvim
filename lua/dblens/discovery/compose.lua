--- docker-compose services that are databases, read straight out of the file's text.
---
--- Deliberately NOT a YAML parser and deliberately no YAML dependency: a compose file is read
--- line by line for the four things a connection needs — the service name, its image, a published
--- host port, and its environment. Anything else is skipped, and a file that does not read as
--- expected yields no candidates rather than an error.
local url_mod = require('dblens.discovery.url')

local M = {}

--- Substring of the image name -> adapter kind. Checked in order, so a distribution that spells
--- the engine twice (`bitnami/postgresql`) still lands on one kind.
local IMAGE_KINDS = {
  { match = 'mariadb', kind = 'mariadb' },
  { match = 'postgres', kind = 'postgres' },
  { match = 'postgis', kind = 'postgres' },
  { match = 'pgvector', kind = 'postgres' },
  { match = 'timescale', kind = 'postgres' },
  { match = 'mysql', kind = 'mysql' },
  { match = 'percona', kind = 'mysql' },
  { match = 'mssql', kind = 'mssql' },
  { match = 'sqlserver', kind = 'mssql' },
}

--- Top-level compose keys that are not services, for the legacy v1 layout where services sit at
--- the top level instead of under `services:`.
local NOT_SERVICES = {
  version = true,
  services = true,
  networks = true,
  volumes = true,
  configs = true,
  secrets = true,
  include = true,
  name = true,
}

--- Per kind: which environment variables name the database, the user and the password, and the
--- fallbacks the official images apply when they are absent.
local ENGINE_ENV = {
  postgres = {
    database = { 'POSTGRES_DB', 'POSTGRESQL_DATABASE' },
    user = { 'POSTGRES_USER', 'POSTGRESQL_USERNAME' },
    password = { 'POSTGRES_PASSWORD', 'POSTGRESQL_PASSWORD' },
    default_user = 'postgres',
  },
  mysql = {
    database = { 'MYSQL_DATABASE' },
    user = { 'MYSQL_USER' },
    password = { 'MYSQL_PASSWORD' },
    root_password = { 'MYSQL_ROOT_PASSWORD' },
    default_user = 'root',
  },
  mariadb = {
    database = { 'MARIADB_DATABASE', 'MYSQL_DATABASE' },
    user = { 'MARIADB_USER', 'MYSQL_USER' },
    password = { 'MARIADB_PASSWORD', 'MYSQL_PASSWORD' },
    root_password = { 'MARIADB_ROOT_PASSWORD', 'MYSQL_ROOT_PASSWORD' },
    default_user = 'root',
  },
  mssql = {
    database = {},
    user = {},
    password = { 'MSSQL_SA_PASSWORD', 'SA_PASSWORD' },
    default_user = 'sa',
    default_database = 'master',
  },
}

--- Whether a filename is a compose file.
---@param name string
---@return boolean
function M.is_compose_file(name)
  return name:match('^docker%-compose[%w%.%-_]*%.ya?ml$') ~= nil
    or name:match('^compose[%w%.%-_]*%.ya?ml$') ~= nil
end

---@class dblens.ComposeLine
---@field indent integer
---@field text string

--- Significant lines with their indentation. YAML forbids tabs for indentation, so counting
--- leading spaces is the whole of it.
---@param text string
---@return dblens.ComposeLine[]
local function significant_lines(text)
  local out = {}
  for raw in (text .. '\n'):gmatch('([^\n]*)\n') do
    local line = (raw:gsub('\r$', ''))
    -- A trailing comment is ` # ...`; the space is what keeps it apart from a `#` inside a value.
    local body = vim.trim((vim.trim(line):gsub('%s+#%s.*$', '')))
    if body ~= '' and body:sub(1, 1) ~= '#' then
      out[#out + 1] = { indent = #line:match('^ *'), text = body }
    end
  end
  return out
end

--- Last line of the block owned by the entry on line `at`.
---@param lines dblens.ComposeLine[]
---@param at integer
---@return integer
local function block_end(lines, at)
  local indent = lines[at].indent
  local stop = at + 1
  while stop <= #lines and lines[stop].indent > indent do
    stop = stop + 1
  end
  return stop - 1
end

---@class dblens.ComposeEntry
---@field key string
---@field value string   -- the inline scalar, '' when the value is the block below
---@field from integer   -- first line of that block
---@field to integer     -- last line of that block

--- Direct mapping children of the line range `from..to`.
---@param lines dblens.ComposeLine[]
---@param from integer
---@param to integer
---@return dblens.ComposeEntry[]
local function children(lines, from, to)
  local out = {}
  if from > to or from < 1 then
    return out
  end
  local indent = lines[from].indent
  for at = from, to do
    if lines[at].indent == indent then
      local key, value = lines[at].text:match('^["\']?([%w_.%-]+)["\']?:%s*(.*)$')
      if key then
        out[#out + 1] =
          { key = key, value = value, from = at + 1, to = math.min(block_end(lines, at), to) }
      end
    end
  end
  return out
end

--- Sequence items directly inside the line range, with the `- ` marker removed.
---@return string[]
local function list_items(lines, from, to)
  local out = {}
  if from > to or from < 1 then
    return out
  end
  local indent = lines[from].indent
  for at = from, to do
    local item = lines[at].indent == indent and lines[at].text:match('^%-%s+(.*)$') or nil
    if item then
      out[#out + 1] = item
    end
  end
  return out
end

local function unquote(value)
  return value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
end

--- Every item of a sequence-valued key, in either YAML spelling.
---
--- `ports: ["5432:5432"]` (inline flow) is at least as common as the block form, and reading only
--- the block form made the commonest compose file in the world discover nothing at all.
---@param lines dblens.ComposeLine[]
---@param entry dblens.ComposeEntry
---@return string[]
local function sequence_items(lines, entry)
  local out = list_items(lines, entry.from, entry.to)
  local inline = entry.value:match('^%[(.*)%]$')
  if not inline then
    return out
  end
  for part in inline:gmatch('[^,]+') do
    local item = vim.trim(part)
    if item ~= '' then
      out[#out + 1] = item
    end
  end
  return out
end

--- Substitute `${VAR}`, `${VAR:-default}` and `$VAR` from the compose file's own `.env` values,
--- then the editor's environment. An unresolved reference makes the whole value nil: a literal
--- `${DB_PASSWORD}` is not a password, and passing it on would produce a candidate that lies.
---@param value string
---@param vars table<string, string>
---@return string?
local function interpolate(value, vars)
  if not value:find('$', 1, true) then
    return value
  end
  local unresolved = false
  local function resolve(name, default)
    local found = vars[name] or vim.env[name] or default
    if found == nil or found == '' then
      unresolved = true
      return ''
    end
    return found
  end
  local out = value:gsub('%${([^}]*)}', function(body)
    local name, default = body:match('^([%w_]+):?%-(.*)$')
    if name then
      return resolve(name, default)
    end
    name = body:match('^([%w_]+)$')
    if not name then
      unresolved = true
      return ''
    end
    return resolve(name, nil)
  end)
  out = out:gsub('%$([%w_]+)', function(name)
    return resolve(name, nil)
  end)
  if unresolved then
    return nil
  end
  return out
end

--- The service's environment, from either the mapping form or the `KEY=value` list form.
---@return table<string, string>
local function service_environment(lines, entry, vars)
  local out = {}
  local function put(key, value)
    local resolved = value ~= nil and interpolate(unquote(vim.trim(value)), vars) or nil
    if key and resolved and resolved ~= '' and out[key] == nil then
      out[key] = resolved
    end
  end
  for _, item in ipairs(sequence_items(lines, entry)) do
    local key, value = unquote(item):match('^([%w_.]+)=(.*)$')
    put(key, value)
  end
  for _, child in ipairs(children(lines, entry.from, entry.to)) do
    put(child.key, child.value)
  end
  return out
end

--- The host port a `ports:` item publishes, and the container port it maps to.
---
--- `5432` alone publishes nothing predictable (docker picks an ephemeral host port), so it is not
--- a target dblens can offer.
---@param item string
---@return integer? host_port, integer? container_port
local function published(item)
  local parts = {}
  for part in unquote(item):gmatch('[^:]+') do
    parts[#parts + 1] = part
  end
  if #parts < 2 then
    return nil, nil
  end
  -- `ip:host:container` and `host:container`; a range publishes its first port first.
  local host = tonumber(parts[#parts - 1]:match('^%d+'))
  local container = tonumber(parts[#parts]:match('^%d+'))
  return host, container
end

--- The host port to connect on: the mapping onto the engine's own port when there is one, else
--- the first mapping that publishes anything.
---@return integer?
local function host_port(lines, entry, vars, default_port)
  local first = nil
  for _, item in ipairs(sequence_items(lines, entry)) do
    local resolved = interpolate(item, vars)
    if resolved then
      local host, container = published(resolved)
      if host then
        if container == default_port then
          return host
        end
        first = first or host
      end
    end
  end
  if first then
    return first
  end
  -- Long form: `- target: 5432` / `published: 5433`, which sit at different indents inside the
  -- same sequence item, so the whole block is scanned rather than its direct children.
  for at = entry.from, entry.to do
    local value = lines[at].text:match('^%-?%s*published:%s*(.*)$')
    local resolved = value and interpolate(unquote(vim.trim(value)), vars) or nil
    local port = resolved and tonumber(resolved:match('^%d+') or '') or nil
    if port then
      return port
    end
  end
  return nil
end

---@param image string
---@return string?
local function kind_for_image(image)
  local name = unquote(image):lower()
  for _, entry in ipairs(IMAGE_KINDS) do
    if name:find(entry.match, 1, true) then
      return entry.kind
    end
  end
  return nil
end

---@param env table<string, string>
---@param names string[]
---@return string?
local function first_of(env, names)
  for _, name in ipairs(names or {}) do
    if env[name] and env[name] ~= '' then
      return env[name]
    end
  end
  return nil
end

--- One service, or nil when it is not a database dblens can reach.
---@param service dblens.ComposeEntry
---@param lines dblens.ComposeLine[]
---@param vars table<string, string>
---@param source string
---@return dblens.RawCandidate?
local function service_candidate(service, lines, vars, source)
  local kind, ports, env = nil, nil, {}
  for _, child in ipairs(children(lines, service.from, service.to)) do
    if child.key == 'image' then
      kind = kind_for_image(interpolate(child.value, vars) or child.value)
    elseif child.key == 'ports' then
      ports = child
    elseif child.key == 'environment' then
      env = service_environment(lines, child, vars)
    end
  end
  if not kind or not ports then
    return nil
  end

  local settings = ENGINE_ENV[kind]
  local port = host_port(lines, ports, vars, url_mod.DEFAULT_PORTS[kind])
  if not port then
    return nil
  end
  local user = first_of(env, settings.user) or settings.default_user
  -- The postgres image creates a database named after its user when POSTGRES_DB is unset.
  local database = first_of(env, settings.database) or settings.default_database or user
  local secret = first_of(env, settings.password) or first_of(env, settings.root_password)
  return {
    name = service.key,
    kind = kind,
    target = { host = 'localhost', port = port, user = user, database = database },
    secret = secret,
    origin = 'compose',
    source = source,
  }
end

--- The service entries in the file, under `services:` or, for the legacy layout, at the top level.
---@return dblens.ComposeEntry[]
local function service_entries(lines)
  local top = children(lines, 1, #lines)
  for _, entry in ipairs(top) do
    if entry.key == 'services' then
      return children(lines, entry.from, entry.to)
    end
  end
  local out = {}
  for _, entry in ipairs(top) do
    if not NOT_SERVICES[entry.key] then
      out[#out + 1] = entry
    end
  end
  return out
end

--- Every database service the compose file publishes a host port for.
---@param text string
---@param opts { source: string, vars: table<string, string>? }
---@return dblens.RawCandidate[]
function M.parse(text, opts)
  assert(type(text) == 'string', 'discovery.compose.parse: expected file text')
  assert(type(opts.source) == 'string' and opts.source ~= '', 'discovery.compose: needs a source')
  local lines = significant_lines(text)
  local vars = opts.vars or {}
  local out = {}
  for _, service in ipairs(service_entries(lines)) do
    local candidate = service_candidate(service, lines, vars, opts.source)
    if candidate then
      out[#out + 1] = candidate
    end
  end
  return out
end

return M
