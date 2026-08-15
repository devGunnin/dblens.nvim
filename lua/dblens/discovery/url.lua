--- Connection URLs found in workspace files, parsed into a target description.
---
--- The input is UNTRUSTED: it comes from a `.env` or a config file nobody vetted. Nothing here
--- expands, evaluates, opens or connects to anything — it returns a plain table that the caller
--- turns into a spec and validates like any other. A password in the URL is returned as `secret`,
--- which is a value the caller keeps in memory; it is never part of a spec.
local M = {}

--- URL scheme -> adapter kind, after the scheme has been reduced to the engine it names.
local SCHEMES = {
  postgres = 'postgres',
  postgresql = 'postgres',
  pg = 'postgres',
  cockroachdb = 'postgres',
  cockroach = 'postgres',
  mysql = 'mysql',
  mysql2 = 'mysql',
  mariadb = 'mariadb',
  sqlite = 'sqlite',
  sqlite3 = 'sqlite',
  duckdb = 'duckdb',
  duck = 'duckdb',
  mssql = 'mssql',
  sqlserver = 'mssql',
}

--- Kinds whose database IS a local file, so the URL carries a path rather than an authority.
local FILE_KINDS = { sqlite = true, duckdb = true }

local DEFAULT_PORTS = { postgres = 5432, mysql = 3306, mariadb = 3306, mssql = 1433 }

--- Paths that name no file: an in-memory database is not something dblens can open.
local NO_FILE = { [''] = true, [':memory:'] = true, ['memory'] = true, ['/:memory:'] = true }

local function percent_decode(text)
  return (text:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@param rest string  -- everything after `scheme:`
---@return dblens.DiscoveredTarget?
local function file_target(kind, rest)
  local path = rest:gsub('%?.*$', '')
  if path:sub(1, 3) == '///' then
    -- `sqlite:///x` and `sqlite:////x` differ by convention, not by meaning: whether the path is
    -- relative to the project or absolute is settled by the caller, against the filesystem.
    path = (path:sub(3):gsub('^//+', '/'))
  elseif path:sub(1, 2) == '//' then
    path = path:sub(3)
  end
  path = percent_decode(path)
  if NO_FILE[path] then
    return nil
  end
  return { kind = kind, path = path }
end

--- Where the authority ends: the first `/`, unless an unencoded `/` sits inside the password.
---
--- `user:pa/ss@host/db` is invalid per RFC 3986 but routine in a real `.env` — random and base64
--- secrets carry `/` — and splitting on the first one framed the password as the host, so the
--- user's actual database never appeared. The authority is extended to the last `@` only when the
--- part before the first `/` opened a userinfo and did not close it, so an ordinary `@` in a path
--- is left alone.
---@param rest string  -- query already removed
---@return integer? slash  -- nil when the whole of `rest` is the authority
local function authority_end(rest)
  local slash = rest:find('/', 1, true)
  if not slash then
    return nil
  end
  local head = rest:sub(1, slash - 1)
  if head:find('@', 1, true) or not head:find(':', 1, true) then
    return slash
  end
  local at = rest:find('@[^@]*$')
  if not at or at < slash then
    return slash
  end
  return rest:find('/', at + 1, true)
end

--- Split `//user:pass@host:port/db?query` into its three parts, the leading `//` already gone.
---@return string authority, string path, string query
local function split_authority(rest)
  local query = ''
  local question = rest:find('?', 1, true)
  if question then
    query, rest = rest:sub(question + 1), rest:sub(1, question - 1)
  end
  local slash = authority_end(rest)
  if not slash then
    return rest, '', query
  end
  return rest:sub(1, slash - 1), rest:sub(slash + 1), query
end

---@return string? user, string? secret
local function split_userinfo(userinfo)
  if userinfo == '' then
    return nil, nil
  end
  local user, secret = userinfo:match('^([^:]*):(.*)$')
  if not user then
    return percent_decode(userinfo), nil
  end
  return user ~= '' and percent_decode(user) or nil, secret ~= '' and percent_decode(secret) or nil
end

---@return string? host, integer? port
local function split_hostport(hostport)
  -- `[::1]:5432` — the brackets are what tells an IPv6 address's colons from the port's.
  local bracketed = hostport:match('^%[(.-)%]')
  if bracketed then
    return bracketed, tonumber(hostport:match('%]:(%d+)$') or '')
  end
  local host, port = hostport:match('^([^:]*):(%d*)$')
  if not host then
    return hostport ~= '' and percent_decode(hostport) or nil, nil
  end
  return host ~= '' and percent_decode(host) or nil, tonumber(port)
end

---@param query string
---@return string? sslmode
local function sslmode_of(query)
  for pair in query:gmatch('[^&;]+') do
    local key, value = pair:match('^([^=]+)=(.*)$')
    if key and key:lower() == 'sslmode' and value ~= '' then
      return percent_decode(value)
    end
  end
  return nil
end

---@param kind string
---@param rest string
---@return dblens.DiscoveredTarget?
local function server_target(kind, rest)
  if rest:sub(1, 2) ~= '//' then
    return nil
  end
  local authority, path, query = split_authority(rest:sub(3))
  local userinfo, hostport = authority:match('^(.*)@(.*)$')
  local user, secret = split_userinfo(userinfo or '')
  local host, port = split_hostport(hostport or authority)
  -- Only the first path segment is the database; anything after it belongs to a driver dblens
  -- does not speak, and passing it on would name a database that does not exist.
  local database = percent_decode(path:match('^[^/]*') or '')
  return {
    kind = kind,
    host = host or 'localhost',
    port = port or DEFAULT_PORTS[kind],
    user = user,
    -- libpq falls back to the user name when the URL names no database; the other engines have
    -- no such default, and a candidate without one fails validation and is dropped.
    database = database ~= '' and database or (kind == 'postgres' and user or nil),
    sslmode = kind == 'postgres' and sslmode_of(query) or nil,
    secret = secret,
  }
end

---@class dblens.DiscoveredTarget
---@field kind string
---@field path string?     -- file-backed kinds only
---@field host string?
---@field port integer?
---@field user string?
---@field database string?
---@field sslmode string?
---@field secret string?   -- kept in memory by the caller; never written into a spec

--- The engine a scheme names, and everything after it.
---
--- SQLAlchemy and Django spell the Python driver into the scheme (`postgresql+psycopg`), and JDBC
--- nests the real URL behind `jdbc:`. Both still name one engine, so both are reduced to it. What
--- follows is parsed by the ordinary rules, which is deliberate: a driver-specific spelling
--- (`jdbc:sqlserver://host;databaseName=x`) then yields no database and is dropped by validation
--- rather than turned into an invented target.
---@param url string
---@return string? scheme, string? rest
local function split_scheme(url)
  local head, tail = url:match('^(%a[%w%+%.%-]*):(.*)$')
  if head and head:lower() == 'jdbc' then
    head, tail = tail:match('^(%a[%w%+%.%-]*):(.*)$')
  end
  if not head then
    return nil, nil
  end
  -- `postgresql+psycopg2` -> `postgresql`; a scheme with no `+` is unchanged.
  return head:match('^([^+]+)'), tail
end

--- Parse a database connection URL.
---
--- Returns nil for anything that is not one — an unknown scheme, a bare string, an in-memory
--- database — because callers feed this every value of every `.env` they find.
---@param url string
---@return dblens.DiscoveredTarget?
function M.parse(url)
  if type(url) ~= 'string' or url == '' then
    return nil
  end
  local scheme, rest = split_scheme(url)
  if not scheme then
    return nil
  end
  local kind = SCHEMES[scheme:lower()]
  if not kind then
    return nil
  end
  if FILE_KINDS[kind] then
    return file_target(kind, rest)
  end
  return server_target(kind, rest)
end

--- Whether a string even looks like a URL, so a caller can skip the parse for ordinary values.
---@param value string
---@return boolean
function M.looks_like_url(value)
  return type(value) == 'string' and value:match('^%a[%w%+%.%-]*:') ~= nil
end

M.DEFAULT_PORTS = DEFAULT_PORTS

return M
