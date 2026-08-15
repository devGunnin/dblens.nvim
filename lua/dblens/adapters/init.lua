--- Adapter registry.
---
--- An adapter is a pure description of one database client: how to invoke it, how to decode its
--- output, and how to phrase the statements dblens needs. Adapters never touch buffers, never
--- run processes and hold no state, so every one of them is unit-testable without a server.
---
--- What makes a LOCKED connection read-only on this engine, and how strong that is. Every adapter
--- states it, because they are NOT equal and a UI that showed one word for all of them would be
--- lying about the weakest:
---  * `file-open` and `session-and-transaction` are STRONG -- the ENGINE refuses the write, so no
---    classifier mistake can produce one.
---  * `classifier` is BEST-EFFORT -- SQL Server has no read-only transaction and no read-only
---    connection mode, so the refusal is dblens's own and a bug in it is a write. A read-only SQL
---    login is the only hard boundary there.
---@class dblens.ReadOnlyEnforcement
---@field mechanism 'file-open'|'session-and-transaction'|'classifier'
---@field strength 'strong'|'best-effort'
---@field summary string  -- one line, shown by `:checkhealth dblens` and the docs

---@class dblens.Adapter
---@field kind string
---@field label string
---@field dialect dblens.Dialect
---@field caps { schemas: boolean, ddl: 'native'|'reconstructed', explain: boolean, explain_analyze: boolean, estimate_rows: boolean }
---@field read_only_enforcement dblens.ReadOnlyEnforcement
---@field fields { name: string, label: string, required: boolean?, default: any }[]
---@field validate fun(spec: dblens.ConnectionSpec): string?
---@field describe fun(spec: dblens.ConnectionSpec): string
---@field command fun(spec, secret: string?, mode: 'records'|'raw', clients: table): { argv: string[], env: table? }
---@field read_only_script fun(statement: string): string  -- what a read_only run sends on stdin
---@field decode fun(stdout: string, opts: table?): dblens.ResultSet
---@field estimate nil|fun(statement: string): { sql: string, mode: string, parse: fun(decoded, raw): integer? }
---@field file nil|fun(spec): string  -- set only by adapters whose database IS a local file
---@field sql table

local M = {}

local REGISTRY = {
  sqlite = 'dblens.adapters.sqlite',
  postgres = 'dblens.adapters.postgres',
  mysql = 'dblens.adapters.mysql',
  mariadb = 'dblens.adapters.mariadb',
  duckdb = 'dblens.adapters.duckdb',
  mssql = 'dblens.adapters.mssql',
}

--- Alternate spellings accepted in connection specs. `mariadb` used to be an alias for `mysql`
--- and is now its own adapter: it drives the `mariadb` client binary, which a MariaDB install
--- ships instead of `mysql`.
local ALIASES = {
  sqlite3 = 'sqlite',
  postgresql = 'postgres',
  pg = 'postgres',
  psql = 'postgres',
  maria = 'mariadb',
  duck = 'duckdb',
  sqlserver = 'mssql',
  ['sql-server'] = 'mssql',
  tsql = 'mssql',
  sqlcmd = 'mssql',
}

local loaded = {}

--- Canonical adapter kind for a user-supplied name, or nil when unknown.
---@param kind string
---@return string?
function M.normalize(kind)
  if type(kind) ~= 'string' then
    return nil
  end
  local key = kind:lower()
  key = ALIASES[key] or key
  return REGISTRY[key] and key or nil
end

--- Look up an adapter.
---@param kind string
---@return dblens.Adapter? adapter, string? error
function M.get(kind)
  local key = M.normalize(kind)
  if not key then
    return nil,
      ('unknown database kind `%s` (known: %s)'):format(
        tostring(kind),
        table.concat(M.kinds(), ', ')
      )
  end
  if not loaded[key] then
    local adapter = require(REGISTRY[key])
    assert(adapter.kind == key, 'adapters: registry key must match adapter kind')
    -- Checked at load, not at review time: an adapter that forgot to say how its LOCKED mode is
    -- enforced would otherwise be shown to the user under the same word as the strong ones.
    local enforcement = adapter.read_only_enforcement
    assert(
      type(enforcement) == 'table'
        and type(enforcement.mechanism) == 'string'
        and type(enforcement.summary) == 'string'
        and (enforcement.strength == 'strong' or enforcement.strength == 'best-effort'),
      ('adapters: `%s` must declare read_only_enforcement'):format(key)
    )
    loaded[key] = adapter
  end
  return loaded[key], nil
end

--- Every registered kind, in a stable order.
---@return string[]
function M.kinds()
  local out = vim.tbl_keys(REGISTRY)
  table.sort(out)
  return out
end

return M
