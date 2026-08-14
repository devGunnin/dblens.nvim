--- Adapter registry.
---
--- An adapter is a pure description of one database client: how to invoke it, how to decode its
--- output, and how to phrase the statements dblens needs. Adapters never touch buffers, never
--- run processes and hold no state, so every one of them is unit-testable without a server.
---
---@class dblens.Adapter
---@field kind string
---@field label string
---@field dialect dblens.Dialect
---@field caps { schemas: boolean, ddl: 'native'|'reconstructed', explain: boolean, explain_analyze: boolean, estimate_rows: boolean }
---@field fields { name: string, label: string, required: boolean?, default: any }[]
---@field validate fun(spec: dblens.ConnectionSpec): string?
---@field describe fun(spec: dblens.ConnectionSpec): string
---@field command fun(spec, secret: string?, mode: 'records'|'raw', clients: table): { argv: string[], env: table? }
---@field decode fun(stdout: string, opts: table?): dblens.ResultSet
---@field estimate nil|fun(statement: string): { sql: string, mode: string, parse: fun(decoded, raw): integer? }
---@field sql table

local M = {}

local REGISTRY = {
  sqlite = 'dblens.adapters.sqlite',
  postgres = 'dblens.adapters.postgres',
  mysql = 'dblens.adapters.mysql',
}

--- Alternate spellings accepted in connection specs.
local ALIASES = {
  sqlite3 = 'sqlite',
  postgresql = 'postgres',
  pg = 'postgres',
  psql = 'postgres',
  mariadb = 'mysql',
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
    loaded[key] = require(REGISTRY[key])
    assert(loaded[key].kind == key, 'adapters: registry key must match adapter kind')
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
