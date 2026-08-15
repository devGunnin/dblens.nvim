--- `.env` files: the `KEY=value` pairs in one, and the connection candidates they imply.
---
--- Tolerant on purpose. This is somebody else's file in somebody else's format, so a line that
--- does not parse is skipped rather than fatal, and a value that does not describe a database is
--- simply not a candidate. A password read out of one stays in the returned candidate, in memory.
local url_mod = require('dblens.discovery.url')

local M = {}

--- The engine word inside a variable name -> adapter kind.
local FAMILY_KINDS = {
  PG = 'postgres',
  PGSQL = 'postgres',
  POSTGRES = 'postgres',
  POSTGRESQL = 'postgres',
  MYSQL = 'mysql',
  MARIADB = 'mariadb',
  MSSQL = 'mssql',
  SQLSERVER = 'mssql',
}

--- Families that name a connection without naming an engine. Their values fill the gaps in an
--- engine group under the same prefix, which is what makes `<P>_POSTGRES_*` plus a standalone
--- `<P>_DB_PORT` one connection rather than two halves.
local GENERIC_FAMILIES = { DB = true, DATABASE = true }

--- Variable-name suffix -> the field it fills. Longest first, and every one is tried until the
--- rest of the name resolves to a family: `<P>_DB_NAME` is `NAME` of the `DB` family, while
--- `<P>_POSTGRES_DB_NAME` is `DB_NAME` of the postgres one.
local ROLE_SUFFIXES = {
  { suffix = 'DATABASE_NAME', role = 'database' },
  { suffix = 'DB_NAME', role = 'database' },
  { suffix = 'DBNAME', role = 'database' },
  { suffix = 'DATABASE', role = 'database' },
  { suffix = 'NAME', role = 'database' },
  { suffix = 'DB', role = 'database' },
  { suffix = 'USERNAME', role = 'user' },
  { suffix = 'USER', role = 'user' },
  { suffix = 'PASSWORD', role = 'password' },
  { suffix = 'PASS', role = 'password' },
  { suffix = 'PWD', role = 'password' },
  { suffix = 'HOSTNAME', role = 'host' },
  { suffix = 'HOST', role = 'host' },
  { suffix = 'PORT', role = 'port' },
}

--- libpq and the mysql client spell some variables with no separator, or with a word in the
--- middle. Listed rather than pattern-matched: a general glue rule would read ordinary variables
--- (`GITHUB_USER`) as connection settings.
local ALIASES = {
  PGDATABASE = { family = 'PG', role = 'database' },
  PGHOST = { family = 'PG', role = 'host' },
  PGPORT = { family = 'PG', role = 'port' },
  PGUSER = { family = 'PG', role = 'user' },
  PGPASSWORD = { family = 'PG', role = 'password' },
  MYSQL_TCP_PORT = { family = 'MYSQL', role = 'port' },
}

--- A published host port that names its engine on its own, for a group whose variables never say
--- which engine they describe.
local PORT_KINDS = { [5432] = 'postgres', [3306] = 'mysql', [1433] = 'mssql' }

--- Hosts that are already this machine. Anything else without a dot is a compose service name:
--- reachable from a sibling container, not from the editor.
local LOOPBACK = {
  localhost = true,
  ['127.0.0.1'] = true,
  ['::1'] = true,
  ['0.0.0.0'] = true,
}

--- Strip surrounding quotes, or an inline `#` comment from an unquoted value.
---@param value string
---@return string
local function unquote(value)
  local quoted = value:match('^"(.*)"%s*$') or value:match("^'(.*)'%s*$")
  if quoted then
    return quoted
  end
  return vim.trim((value:gsub('%s+#.*$', '')))
end

--- Parse dotenv text into its pairs, in file order.
---@param text string
---@return { key: string, value: string }[]
function M.parse(text)
  assert(type(text) == 'string', 'discovery.env.parse: expected file text')
  local out = {}
  for line in text:gmatch('[^\r\n]+') do
    local body = vim.trim(line)
    if body ~= '' and body:sub(1, 1) ~= '#' then
      local key, value = body:gsub('^export%s+', ''):match('^([%w_.]+)%s*=%s*(.*)$')
      if key then
        out[#out + 1] = { key = key, value = unquote(value) }
      end
    end
  end
  return out
end

--- Split a variable name's head into the project's own prefix and the family it ends with.
---@param head string  -- the name with its role suffix removed
---@return string? prefix, string? family
local function split_family(head)
  if FAMILY_KINDS[head] or GENERIC_FAMILIES[head] then
    return '', head
  end
  local prefix, family = head:match('^(.+)_([^_]+)$')
  if family and (FAMILY_KINDS[family] or GENERIC_FAMILIES[family]) then
    return prefix, family
  end
  return nil, nil
end

--- What connection field, of what engine, under what project prefix, a variable name describes.
---
--- A bare `PORT` or `HOST` resolves to nothing on purpose: without a family naming a database
--- they are the web server's, and reading them as one would offer a connection to the app itself.
---@param key string  -- upper-cased
---@return { prefix: string, family: string, role: string }?
local function decompose(key)
  local alias = ALIASES[key]
  if alias then
    return { prefix = '', family = alias.family, role = alias.role }
  end
  for _, entry in ipairs(ROLE_SUFFIXES) do
    local head = key:match('^(.*)_' .. entry.suffix .. '$')
    if head then
      local prefix, family = split_family(head)
      if family then
        return { prefix = prefix, family = family, role = entry.role }
      end
    end
  end
  return nil
end

---@class dblens.EnvGroup
---@field prefix string
---@field kind string?   -- nil until an engine is known; a generic group has none of its own
---@field values table<string, string>  -- role -> value

---@class dblens.EnvVars
---@field groups dblens.EnvGroup[]                 -- engine groups then generic ones, file order
---@field generic table<string, dblens.EnvGroup>   -- the `<prefix>_DB_*` variables, by prefix
---@field engines table<string, integer>           -- engine groups per prefix
---@field ports table<string, integer>             -- host port named under a prefix, by prefix
---@field urls { key: string, kind: string }[]     -- values that parsed as a URL, in file order

--- The bucket a variable belongs to, created on first sight. Engine groups are one per (prefix,
--- engine); everything generic shares one group per prefix.
---@param vars dblens.EnvVars
---@param by_id table<string, dblens.EnvGroup>
---@param part { prefix: string, family: string, role: string }
---@return dblens.EnvGroup
local function group_for(vars, by_id, part)
  local kind = FAMILY_KINDS[part.family]
  local id = part.prefix .. '|' .. (kind or '')
  if not by_id[id] then
    by_id[id] = { prefix = part.prefix, kind = kind, values = {} }
    vars.groups[#vars.groups + 1] = by_id[id]
    if kind then
      vars.engines[part.prefix] = (vars.engines[part.prefix] or 0) + 1
    else
      vars.generic[part.prefix] = by_id[id]
    end
  end
  return by_id[id]
end

--- Bucket every connection variable in the file by project prefix and engine.
---@param entries { key: string, value: string }[]
---@return dblens.EnvVars
local function collect(entries)
  local vars = { groups = {}, generic = {}, engines = {}, ports = {}, urls = {} }
  local by_id = {}
  for _, entry in ipairs(entries) do
    local part = entry.value ~= '' and decompose(entry.key:upper()) or nil
    if part then
      local group = group_for(vars, by_id, part)
      if group.values[part.role] == nil then
        group.values[part.role] = entry.value
        vars.ports[part.prefix] = vars.ports[part.prefix]
          or (part.role == 'port' and tonumber(entry.value) or nil)
      end
    end
  end
  return vars
end

--- Resolve a discovered file path against the directory of the file that named it, the way the
--- application reading that `.env` would.
---
--- A leading `/` is not decided: `sqlite:///db/dev.sqlite3` is a path relative to the project in
--- some frameworks and an absolute one in others. The file that exists settles it, and when
--- neither does, the path is left as written so the error names what was actually asked for.
---@param path string
---@param dir string
---@return string
local function absolute(path, dir)
  if path:sub(1, 1) == '~' then
    return path
  end
  if path:sub(1, 1) ~= '/' then
    return vim.fs.normalize(dir .. '/' .. path)
  end
  if vim.uv.fs_stat(path) then
    return vim.fs.normalize(path)
  end
  local relative = vim.fs.normalize(dir .. '/' .. path:sub(2))
  if vim.uv.fs_stat(relative) then
    return relative
  end
  return vim.fs.normalize(path)
end

---@param target dblens.DiscoveredTarget
---@param key string
---@param opts { source: string, dir: string }
---@return dblens.RawCandidate
local function candidate_from_target(target, key, opts)
  local secret = target.secret
  target.secret = nil
  if target.path then
    target.path = absolute(target.path, opts.dir)
  end
  local kind = target.kind
  target.kind = nil
  return {
    name = key,
    kind = kind,
    target = target,
    secret = secret,
    origin = 'env',
    source = opts.source,
  }
end

--- Whether a host names a container on a compose network rather than something this machine can
--- reach. A dot makes it a real name, a `:` an IPv6 address, a `/` a libpq socket directory.
---@param host string?
---@return boolean
local function is_container_host(host)
  if type(host) ~= 'string' or host == '' or LOOPBACK[host:lower()] then
    return false
  end
  return host:find('[.:/]') == nil
end

--- The port a prefix publishes on this machine, looking outwards from the variable that asked:
--- `TACTICA_DATABASE_URL` is answered by `TACTICA_DB_PORT`, and by a bare `DB_PORT` after that.
---@param ports table<string, integer>
---@param key string  -- upper-cased variable name, or a group's prefix
---@return integer?
local function published_port(ports, key)
  local at = key
  while true do
    if ports[at] then
      return ports[at]
    end
    if at == '' then
      return nil
    end
    at = at:match('^(.*)_[^_]*$') or ''
  end
end

--- What makes two of this file's candidates the same database, so a group and the URL beside it
--- describing one connection are offered once. First wins: the URL, which carries a password.
---@param candidate dblens.RawCandidate
---@return string
local function identity(candidate)
  local target = candidate.target
  return ('%s|%s|%s|%s|%s'):format(
    candidate.kind,
    target.path or '',
    target.host or '',
    target.port or '',
    target.database or ''
  )
end

--- Add a candidate, and — when it points at a container the editor cannot reach and the file
--- publishes a port for it — the localhost connection that same database answers on.
---
--- Both are offered rather than either replaced: the internal one is what the file says, and only
--- the user knows whether the stack is up. Their provenance lines differ, which is what tells
--- them apart in the picker.
---@param out dblens.RawCandidate[]
---@param seen table<string, boolean>
---@param candidate dblens.RawCandidate
---@param hint_key string  -- what to look a published port up by
---@param vars dblens.EnvVars
local function offer(out, seen, candidate, hint_key, vars)
  local key = identity(candidate)
  if not seen[key] then
    seen[key] = true
    out[#out + 1] = candidate
  end
  local target = candidate.target
  if not is_container_host(target.host) or not target.database then
    return
  end
  local port = published_port(vars.ports, hint_key)
  if not port then
    return
  end
  local twin = vim.deepcopy(candidate)
  twin.name = target.database
  twin.target.host = 'localhost'
  twin.target.port = port
  local twin_key = identity(twin)
  if not seen[twin_key] then
    seen[twin_key] = true
    out[#out + 1] = twin
  end
end

--- The engine a group without one describes: what a URL under the same prefix says, else what
--- its own published port can only be. Nothing else — an invented engine is an invented target.
---@param group dblens.EnvGroup
---@param vars dblens.EnvVars
---@return string?
local function inferred_kind(group, vars)
  local under = group.prefix == '' and '' or group.prefix .. '_'
  for _, entry in ipairs(vars.urls) do
    if entry.key:sub(1, #under) == under then
      return entry.kind
    end
  end
  return PORT_KINDS[tonumber(group.values.port or '') or 0]
end

--- One variable group as a connection, or nil when it does not describe one.
---
--- Only a group that NAMES a database is a candidate: without it there is nothing to connect to,
--- only a host that might serve one. An absent host is localhost and an absent port the engine's
--- default — neither is guessed at from anything else.
---@param group dblens.EnvGroup
---@param vars dblens.EnvVars
---@param opts { source: string }
---@return dblens.RawCandidate?, string? hint_key
local function group_candidate(group, vars, opts)
  assert(type(group.prefix) == 'string', 'discovery.env: a group needs a prefix')
  -- The generic variables belong to a prefix's one engine; with two they belong to neither.
  local shared = vars.engines[group.prefix] == 1 and vars.generic[group.prefix] or nil
  local function value(role)
    return group.values[role] or (shared and shared.values[role]) or nil
  end
  local database = value('database')
  local kind = group.kind or inferred_kind(group, vars)
  if not database or database == '' or not kind then
    return nil
  end
  return {
    name = database,
    kind = kind,
    target = {
      host = value('host') or 'localhost',
      port = tonumber(value('port') or '') or url_mod.DEFAULT_PORTS[kind],
      user = value('user'),
      database = database,
    },
    secret = value('password'),
    origin = 'env',
    source = opts.source,
  },
    group.prefix
end

--- Every connection the file describes: each value that parses as a database URL, then the
--- variable groups — `PG*` and `MYSQL_*`, and any project-prefixed group beside them.
---@param text string
---@param opts { source: string, dir: string }  -- provenance, and where a relative path resolves
---@return dblens.RawCandidate[]
function M.candidates(text, opts)
  assert(type(opts.source) == 'string' and opts.source ~= '', 'discovery.env: needs a source')
  assert(type(opts.dir) == 'string' and opts.dir ~= '', 'discovery.env: needs a directory')

  local entries = M.parse(text)
  local vars = collect(entries)
  local out, seen = {}, {}
  for _, entry in ipairs(entries) do
    if url_mod.looks_like_url(entry.value) then
      local target = url_mod.parse(entry.value)
      if target then
        local candidate = candidate_from_target(target, entry.key, opts)
        vars.urls[#vars.urls + 1] = { key = entry.key:upper(), kind = candidate.kind }
        offer(out, seen, candidate, entry.key:upper(), vars)
      end
    end
  end

  for _, group in ipairs(vars.groups) do
    -- A generic group under a prefix that also names an engine has already been read as part of
    -- it; on its own it is a connection whose engine has to be inferred.
    if group.kind or not vars.engines[group.prefix] then
      local candidate, hint_key = group_candidate(group, vars, opts)
      if candidate then
        offer(out, seen, candidate, hint_key, vars)
      end
    end
  end
  return out
end

return M
