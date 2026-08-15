--- `.env` files: the `KEY=value` pairs in one, and the connection candidates they imply.
---
--- Tolerant on purpose. This is somebody else's file in somebody else's format, so a line that
--- does not parse is skipped rather than fatal, and a value that does not describe a database is
--- simply not a candidate. A password read out of one stays in the returned candidate, in memory.
local url_mod = require('dblens.discovery.url')

local M = {}

--- Variable groups that describe a connection without a URL. A group is only a candidate when the
--- database is named: without it there is nothing to connect to, only a host that might serve one.
local GROUPS = {
  {
    kind = 'postgres',
    database = 'PGDATABASE',
    host = 'PGHOST',
    port = 'PGPORT',
    user = 'PGUSER',
    passwords = { 'PGPASSWORD' },
  },
  {
    kind = 'mysql',
    database = 'MYSQL_DATABASE',
    host = 'MYSQL_HOST',
    port = 'MYSQL_TCP_PORT',
    user = 'MYSQL_USER',
    passwords = { 'MYSQL_PWD', 'MYSQL_PASSWORD' },
  },
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

---@param pairs_list { key: string, value: string }[]
---@return table<string, string>
local function to_map(pairs_list)
  local map = {}
  for _, entry in ipairs(pairs_list) do
    -- First wins: a later duplicate in the same file is the one the shell would overwrite, but
    -- dotenv loaders differ and the first is what the file reads as.
    if map[entry.key] == nil then
      map[entry.key] = entry.value
    end
  end
  return map
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

---@param map table<string, string>
---@param group table
---@param opts { source: string, dir: string }
---@return dblens.RawCandidate?
local function group_candidate(map, group, opts)
  local database = map[group.database]
  if not database or database == '' then
    return nil
  end
  local secret = nil
  for _, name in ipairs(group.passwords) do
    secret = secret or (map[name] ~= '' and map[name] or nil)
  end
  return {
    name = database,
    kind = group.kind,
    target = {
      host = map[group.host] or 'localhost',
      port = tonumber(map[group.port] or '') or url_mod.DEFAULT_PORTS[group.kind],
      user = map[group.user],
      database = database,
    },
    secret = secret,
    origin = 'env',
    source = opts.source,
  }
end

--- Every connection the file describes: each value that parses as a database URL, then the
--- `PG*` / `MYSQL_*` variable groups.
---@param text string
---@param opts { source: string, dir: string }  -- provenance, and where a relative path resolves
---@return dblens.RawCandidate[]
function M.candidates(text, opts)
  assert(type(opts.source) == 'string' and opts.source ~= '', 'discovery.env: needs a source')
  assert(type(opts.dir) == 'string' and opts.dir ~= '', 'discovery.env: needs a directory')

  local entries = M.parse(text)
  local out = {}
  for _, entry in ipairs(entries) do
    if url_mod.looks_like_url(entry.value) then
      local target = url_mod.parse(entry.value)
      if target then
        out[#out + 1] = candidate_from_target(target, entry.key, opts)
      end
    end
  end

  local map = to_map(entries)
  for _, group in ipairs(GROUPS) do
    local candidate = group_candidate(map, group, opts)
    if candidate then
      out[#out + 1] = candidate
    end
  end
  return out
end

return M
