--- PostgreSQL adapter, driven through `psql`.
---
--- Verified live against PostgreSQL 18.4: the safety gate, CSV decoding of values holding
--- control bytes, plain EXPLAIN, batch atomicity and the transaction row guard.
local common = require('dblens.adapters.common')
local protocol = require('dblens.protocol')
local sql = require('dblens.sql')

local dialect = sql.dialects.postgres

local function lit(value)
  return sql.quote_literal(value, dialect)
end

---@type dblens.Adapter
local M = {
  kind = 'postgres',
  label = 'PostgreSQL',
  dialect = dialect,
  --- No native DDL statement, so DDL is reconstructed from the catalog.
  caps = {
    schemas = true,
    ddl = 'reconstructed',
    explain = true,
    explain_analyze = true,
    estimate_rows = true,
  },
  read_only_enforcement = {
    mechanism = 'session-and-transaction',
    strength = 'strong',
    summary = 'every locked run is sent inside a pinned `BEGIN READ ONLY`, on a connection '
      .. 'started with `default_transaction_read_only=on`; the server refuses the write',
  },
  fields = {
    { name = 'host', label = 'Host', default = 'localhost' },
    { name = 'port', label = 'Port', default = 5432 },
    { name = 'user', label = 'User' },
    { name = 'database', label = 'Database', required = true },
    --- libpq's default is `prefer`, which silently falls back to plaintext; set this to
    --- `require` or better when the password travels over a network.
    { name = 'sslmode', label = 'SSL mode' },
  },
}

function M.validate(spec)
  if type(spec.database) ~= 'string' or spec.database == '' then
    return 'postgres connection needs a `database`'
  end
  -- `psql -d` accepts a whole conninfo string, so a stored spec could redirect the connection
  -- (and the password) to a host the UI never shows. A database is a bare name.
  if spec.database:find('[%s=/:]') then
    return 'postgres `database` must be a bare database name, not a connection string'
  end
  -- `host` deliberately keeps `/`: a libpq host may be a Unix socket DIRECTORY. What it must not
  -- be is an option, which is the one shape getopt would not bind to the flag before it.
  local problem = common.argv_field_problem(spec, 'postgres', { 'host', 'user', 'database' })
  if problem then
    return problem
  end
  if spec.port ~= nil and type(spec.port) ~= 'number' then
    return 'postgres `port` must be a number'
  end
  if spec.sslmode ~= nil and type(spec.sslmode) ~= 'string' then
    return 'postgres `sslmode` must be a string'
  end
  return nil
end

function M.describe(spec)
  return ('%s@%s:%s/%s'):format(
    spec.user or '$USER',
    spec.host or 'localhost',
    spec.port or 5432,
    spec.database
  )
end

--- Build the psql invocation. The password never touches argv: psql reads PGPASSWORD.
---
--- `--csv` rather than the control-character framing: psql's unaligned output does not escape
--- control bytes, so a value holding one split a row (or a record) and silently corrupted the
--- grid. CSV quotes anything ambiguous, so only the NULL marker stays a convention.
--- `-f -` makes psql prefix an error with `psql:<stdin>:LINE:`, which is how a failed statement
--- in a committed batch is traced back to the change that produced it.
---
--- A read-only connection sets `default_transaction_read_only` as a STARTUP option, so any
--- transaction the script opens for itself is read-only too. It is the BACKUP; the guarantee is
--- the read-only transaction `read_only_script` wraps the run in.
function M.command(spec, secret, mode, clients)
  local argv = {
    clients.postgres,
    '-X',
    '-q',
    '-v',
    'ON_ERROR_STOP=1',
    '-P',
    'pager=off',
    '-P',
    'footer=off',
  }
  if mode == 'records' then
    vim.list_extend(argv, { '--csv', '-P', 'null=' .. protocol.NULL_SENTINEL })
  else
    vim.list_extend(argv, { '-A', '-t' })
  end
  if spec.host then
    vim.list_extend(argv, { '-h', spec.host })
  end
  if spec.port then
    vim.list_extend(argv, { '-p', tostring(spec.port) })
  end
  if spec.user then
    vim.list_extend(argv, { '-U', spec.user })
  end
  vim.list_extend(argv, { '-d', spec.database, '-f', '-' })

  local env = { PGCONNECT_TIMEOUT = '10' }
  if spec.read_only == true then
    env.PGOPTIONS = '-c default_transaction_read_only=on'
  end
  if secret then
    env.PGPASSWORD = secret
  end
  if spec.sslmode then
    env.PGSSLMODE = spec.sslmode
  end
  return { argv = argv, env = env }
end

--- Opens the read-only transaction and PINS it.
---
--- The pin is load-bearing, not decoration: `BEGIN READ ONLY` alone can still be escalated by
--- `SET TRANSACTION READ WRITE` as the very next statement (verified live on 16.15 — the INSERT
--- landed). PostgreSQL refuses that switch once the transaction has taken a snapshot, and
--- `DECLARE ... CURSOR` takes one while emitting no rows and no output under `-q`.
local READ_ONLY_OPEN = 'BEGIN READ ONLY;\n'
  .. 'DECLARE dblens_read_only_pin NO SCROLL CURSOR FOR SELECT 1;\n'

--- The script a read-only run actually sends.
---
--- Inside the pinned transaction the server refuses every write, and refuses to be talked out of
--- it: `SET default_transaction_read_only = off` only affects LATER transactions, and
--- `SET TRANSACTION READ WRITE` / `set_config('transaction_read_only', ...)` come back
--- `transaction read-write mode must be set before any query`.
---
--- The bare `;` before COMMIT terminates a statement that did not terminate itself; psql accepts
--- the empty statement it makes when the caller already ended with one.
---@param statement string
---@return string
function M.read_only_script(statement)
  assert(
    type(statement) == 'string' and statement ~= '',
    'postgres.read_only_script: needs a statement'
  )
  return READ_ONLY_OPEN .. statement .. '\n;\nCOMMIT;\n'
end

M.decode = protocol.decode_csv

M.sql = {}

function M.sql.schemas()
  return [[SELECT nspname AS name FROM pg_namespace
WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema' ORDER BY nspname]]
end

function M.sql.relations(schema)
  return ([[SELECT table_name AS name,
       CASE WHEN table_type = 'VIEW' THEN 'view' ELSE 'table' END AS kind
FROM information_schema.tables WHERE table_schema = %s ORDER BY kind DESC, table_name]]):format(
    lit(schema)
  )
end

function M.sql.columns(relation)
  local schema, name = lit(relation.schema or 'public'), lit(relation.name)
  return ([[SELECT c.column_name AS name, c.data_type AS type,
       CASE WHEN c.is_nullable = 'NO' THEN 1 ELSE 0 END AS "notnull",
       COALESCE(pk.ordinal_position, 0) AS pk,
       c.column_default AS dflt, fk.ref AS fk
FROM information_schema.columns c
LEFT JOIN (
  SELECT kcu.column_name, kcu.ordinal_position
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
  WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = %s AND tc.table_name = %s
) pk ON pk.column_name = c.column_name
LEFT JOIN (
  SELECT kcu.column_name, ccu.table_name || '.' || ccu.column_name AS ref
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
  JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
  WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = %s AND tc.table_name = %s
) fk ON fk.column_name = c.column_name
WHERE c.table_schema = %s AND c.table_name = %s
ORDER BY c.ordinal_position]]):format(schema, name, schema, name, schema, name)
end

function M.sql.indexes(relation)
  return ([[SELECT i.relname AS name,
       CASE WHEN ix.indisunique THEN 1 ELSE 0 END AS uniq,
       CASE WHEN ix.indisprimary THEN 'pk' ELSE 'i' END AS origin,
       (SELECT string_agg(a.attname, ', ' ORDER BY k.ord)
          FROM unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum) AS cols
FROM pg_index ix
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = %s AND t.relname = %s ORDER BY i.relname]]):format(
    lit(relation.schema or 'public'),
    lit(relation.name)
  )
end

function M.sql.constraints(relation)
  -- contype is a single letter; spell it out so `kind` means the same thing across adapters.
  return ([[SELECT conname AS name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY' WHEN 'u' THEN 'UNIQUE'
                    WHEN 'c' THEN 'CHECK' WHEN 'x' THEN 'EXCLUDE' ELSE contype::text END AS kind,
       pg_get_constraintdef(c.oid) AS detail
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = %s AND t.relname = %s ORDER BY conname]]):format(
    lit(relation.schema or 'public'),
    lit(relation.name)
  )
end

--- No native DDL statement; `dblens.ddl` reconstructs it from the catalog.
function M.sql.ddl(_relation)
  return nil
end

function M.sql.page(relation, opts)
  return common.page(relation, opts, dialect)
end

function M.sql.count(relation, where)
  return common.count(relation, where, dialect)
end

function M.sql.explain(statement, analyze)
  return (analyze and 'EXPLAIN (ANALYZE, BUFFERS) ' or 'EXPLAIN ') .. statement
end

--- Planner row estimate, used to preview the blast radius of a destructive statement without
--- running it. Plain EXPLAIN plans but never executes.
function M.estimate(statement)
  return {
    sql = 'EXPLAIN (FORMAT JSON) ' .. statement,
    mode = 'raw',
    parse = function(_decoded, raw)
      local ok, decoded = pcall(vim.json.decode, vim.trim(raw))
      if not ok or type(decoded) ~= 'table' then
        return nil
      end
      local plan = decoded[1] and decoded[1].Plan
      if type(plan) ~= 'table' or type(plan['Plan Rows']) ~= 'number' then
        return nil
      end
      return math.floor(plan['Plan Rows'])
    end,
  }
end

function M.sql.affected()
  return nil
end

--- How the commit batch opens and closes. Atomicity comes from `ON_ERROR_STOP=1`.
function M.sql.batch_frame()
  return { open = 'BEGIN;', close = 'COMMIT;' }
end

--- A statement that fails unless `count_sql` yields exactly 1, re-checking a queued change's
--- guard inside the committed transaction. RAISE aborts the batch under ON_ERROR_STOP=1.
function M.sql.assert_one(count_sql)
  assert(type(count_sql) == 'string' and count_sql ~= '', 'postgres.assert_one: needs a count')
  return ([[DO $dblens$ BEGIN IF (%s) <> 1 THEN
  RAISE EXCEPTION 'dblens row guard failed'; END IF; END $dblens$]]):format(count_sql)
end

return M
