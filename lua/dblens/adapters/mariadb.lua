--- MariaDB adapter, driven through the `mariadb` client.
---
--- MariaDB speaks the same wire protocol, the same dialect and the same catalog as MySQL, so this
--- adapter REUSES the mysql one for everything that is genuinely identical (XML decoding, the
--- statement builders, the read-only transaction, the row guard) and only states what differs:
--- the client BINARY. A MariaDB install ships `mariadb`; `mysql` is a compatibility symlink that
--- a MariaDB-only machine may not have, which is why this is its own kind rather than an alias.
---
--- Verified live against MariaDB 11.8.8 (`mariadb:11`), through the argv this file builds:
---  * `--xml` output marks NULL with `xsi:nil="true"` and self-closes it, byte-identical in shape
---    to MySQL's, so the mysql decoder is correct here and a mid-row NULL stays in position;
---  * INSERT, UPDATE, DELETE, CREATE, DROP, TRUNCATE and ALTER are ALL refused on a locked
---    connection (error 1792), while reads pass through the wrap and return their rows;
---  * `START TRANSACTION READ WRITE; INSERT ...` and `COMMIT; SET SESSION TRANSACTION READ
---    WRITE; INSERT ...` DO land when sent anyway -- the same documented escape as MySQL, refused
---    by the one-statement rule at the gate rather than by the server.
local mysql = require('dblens.adapters.mysql')

---@type dblens.Adapter
local M = {
  kind = 'mariadb',
  label = 'MariaDB',
  dialect = mysql.dialect,
  caps = mysql.caps,
  read_only_enforcement = {
    mechanism = 'session-and-transaction',
    strength = 'strong',
    summary = 'every locked run is sent inside `START TRANSACTION READ ONLY`, on a session '
      .. 'opened `SET SESSION TRANSACTION READ ONLY`; the server refuses the write',
  },
  fields = {
    { name = 'host', label = 'Host', default = 'localhost' },
    { name = 'port', label = 'Port', default = 3306 },
    { name = 'user', label = 'User' },
    { name = 'database', label = 'Database', required = true },
  },
}

--- Shared with mysql rather than copied. The copy this replaces was missing the bare-name and
--- option-like rules mysql had, so untrusted text reached the mariadb client's option parser.
function M.validate(spec)
  return mysql.validate_as(spec, 'mariadb')
end

M.describe = mysql.describe

--- The mysql invocation on the `mariadb` binary, built by the same function rather than a copy.
---
--- Both switches are load-bearing and neither alone is enough: verified on 11.8.8 that inside a
--- bare `START TRANSACTION READ ONLY` a `CREATE TABLE`/`DROP TABLE` still SUCCEEDS, because DDL
--- commits the transaction implicitly. `SET SESSION TRANSACTION READ ONLY` is what refuses it.
function M.command(spec, secret, mode, clients)
  assert(type(clients.mariadb) == 'string', 'mariadb.command: no `clients.mariadb` configured')
  -- MariaDB's client reads the password from MYSQL_PWD too, so the secret still never hits argv.
  local env = secret and { MYSQL_PWD = secret } or nil
  return { argv = mysql.build_argv(spec, mode, clients.mariadb), env = env }
end

M.read_only_script = mysql.read_only_script
M.decode = mysql.decode
M.estimate = mysql.estimate

--- Statement builders are shared, not copied: they are pure functions of a relation and the
--- dialect, and MariaDB's catalog is MySQL's.
M.sql = mysql.sql

return M
