--- A live connection: its adapter, its resolved secret, its schema cache, its transaction.
---
--- EVERY statement dblens sends — a browsed page, a filter, ad-hoc editor SQL, EXPLAIN, a CRUD
--- write, a committed batch — goes through `Session:run`, and `run` puts every one of them
--- through `Session:gate` first.
---
--- A connection is LOCKED or in EDIT mode, and `Session.locked` is the only thing that says
--- which. It starts from the spec (locked unless `read_only = false`) and `set_locked` flips it
--- at runtime, so unlocking is an explicit user action rather than a hole in the gate.
---
--- What LOCKED GUARANTEES, and what it does not, stated exactly. It is NOT the same on every
--- engine — each adapter states its own strength in `adapter.read_only_enforcement`, and
--- `:checkhealth dblens` shows it.
---
--- GUARANTEED, on every engine whose enforcement is `strong` (sqlite, duckdb, postgres, mysql,
--- mariadb) — no write reaches the database through any normal SQL statement, whatever the
--- dialect and however it is spelled. Two mechanisms, and neither is the classifier:
---  * the ENGINE — the run is sent over a connection opened read-only (`adapter.command`) and,
---    where the engine has one, inside a read-only TRANSACTION (`adapter.read_only_script`). No
---    `SET` in the same run escapes it; sqlite and duckdb need no wrap, their `-readonly` is the
---    file open mode. That holds for ONE statement.
---  * the ONE-STATEMENT rule — postgres and mysql/mariadb let a SECOND statement end or replace
---    that transaction and write in a fresh one, so a locked connection refuses any input
---    `sql.single_statement_problem` cannot prove is exactly one. It is a byte scan, so unlike
---    the four lexer generations before it there is no dialect it can be wrong about.
---
--- NOT GUARANTEED ON mssql, which is why its enforcement is `best-effort`. SQL Server has no
--- read-only transaction and no read-only connection mode, and T-SQL ends a statement at
--- whitespace so the one-statement rule has no `;` to find. There the refusal IS the classifier,
--- and the hard boundary is a read-only SQL login. See `lua/dblens/adapters/mssql.lua`.
---
--- NOT GUARANTEED — a user who ALREADY HOLDS WRITE CREDENTIALS and deliberately calls a function
--- that writes through a side channel. `SELECT dblink_exec('...','INSERT ...')` runs its INSERT
--- in a SECOND postgres backend, outside this transaction, as one statement led by SELECT; the
--- same shape covers `postgres_fdw` and a shell UDF. `sql.side_channel_problem` holds the list of
--- KNOWN names and is BEST-EFFORT ONLY: a `SECURITY DEFINER` wrapper or a rename defeats it, and
--- no client-side check can close that, because only the server knows what a function does.
--- The hard read-only boundary is a database-level read-only ROLE — connect as one when the
--- threat model is a deliberate user rather than an accidental keystroke. See README and
--- `:h dblens-safety-side-channel`.
---
--- What the gate additionally owns:
---  * client meta-commands (`.shell`, `\!`, mysql `system`/`source`) — these run on THIS machine,
---    so no connection setting covers them and the refusal is unconditional;
---  * the destructive-change confirmation, and refusing a write on a read-only connection early
---    so the user gets "connection X is read-only" instead of a server error.
local adapters = require('dblens.adapters')
local catalog = require('dblens.catalog')
local connections = require('dblens.connections')
local exec = require('dblens.exec')
local path_mod = require('dblens.path')
local protocol = require('dblens.protocol')
local sqlmod = require('dblens.sql')
local txn = require('dblens.txn')

local M = {}

local Session = {}
Session.__index = Session

---@class dblens.QueryResult
---@field columns string[]
---@field rows any[][]
---@field malformed integer
---@field truncated boolean
---@field elapsed_ms number
---@field raw string       -- client stdout, needed by 'raw' mode callers

---@param spec dblens.ConnectionSpec
---@param options table
---@param opts { secret: string? }?
--- `opts.secret` is a password the CALLER resolved, for a connection whose secret has no
--- reference to resolve — a discovered one, whose password came out of a workspace file. It stays
--- in this session and in nothing else: the spec does not carry it, so it cannot be persisted.
---@return dblens.Session? session, string? error
function M.new(spec, options, opts)
  local adapter, err = adapters.get(spec.kind)
  if not adapter then
    return nil, err
  end
  local given = opts and opts.secret or nil
  assert(given == nil or type(given) == 'string', 'session.new: secret must be a string')
  return setmetatable({
    spec = spec,
    adapter = adapter,
    options = options,
    catalog = catalog.new(adapter.caps.schemas),
    txn = txn.new(),
    given_secret = given,
    secret = nil,
    connected = false,
    jobs = {},
    -- Runtime mode, and the ONLY source of truth for it. Locked unless the spec opted out, so a
    -- missing, misspelt or non-boolean `read_only` opens locked rather than silently writable.
    locked = spec.read_only ~= false,
  }, Session),
    nil
end

function Session:is_read_only()
  return self.locked == true
end

--- The one label for the connection's mode. LOCKED means the server refuses every write -- except
--- on mssql, where it means dblens does and the server does not (see the header).
---@return 'LOCKED'|'EDIT'
function Session:mode()
  return self:is_read_only() and 'LOCKED' or 'EDIT'
end

--- Flip between LOCKED and EDIT.
---
--- Unlocking is an explicit user action and the only way to write; it does not clear the
--- destructive-change confirmation. Locking is refused while changes are queued, because a
--- locked connection cannot commit them and dropping them would discard the user's work.
---@param locked boolean
---@return boolean ok, string? error
function Session:set_locked(locked)
  assert(type(locked) == 'boolean', 'session:set_locked: locked must be a boolean')
  local queued = self.txn:count()
  if locked and queued > 0 then
    return false,
      ('%d queued change(s) would be stranded: commit or roll back before locking'):format(queued)
  end
  self.locked = locked
  assert(self:is_read_only() == locked, 'session:set_locked: mode did not take')
  return true, nil
end

--- The connection as the CLIENT must see it right now.
---
--- `adapter.command` reads `read_only` off the spec to pick the argv/env switch, and the runtime
--- lock — not the stored spec — decides it, so a toggle changes what the next run spawns with.
---@return dblens.ConnectionSpec
function Session:client_spec()
  if self.spec.read_only == self.locked then
    return self.spec
  end
  return vim.tbl_extend('force', self.spec, { read_only = self.locked })
end

function Session:describe()
  return self.adapter.describe(self.spec)
end

--- Resolve the secret and prove the connection works before the UI shows anything.
---@param on_done fun(ok: boolean, err: string?)
function Session:connect(on_done)
  assert(type(on_done) == 'function', 'session:connect: on_done must be a function')
  -- Every FILE-backed adapter, not just sqlite: both sqlite3 and duckdb silently create a missing
  -- database, so a typo would open an empty one instead of failing.
  if self.adapter.file then
    local path, path_err = path_mod.expand(self.spec.path)
    if not path then
      on_done(false, path_err)
      return
    end
    local missing = vim.fn.filereadable(path) == 0
    if missing and not self.spec.create then
      on_done(false, ('no such database file: %s (set `create = true` to make it)'):format(path))
      return
    end
    -- `create` and LOCKED contradict each other: locked opens the file with `-readonly`, which
    -- cannot create it, and the client's own error ("unable to open database file") tells the
    -- user nothing about why. Name the one setting that makes the documented option work.
    if missing and self.locked then
      on_done(
        false,
        ('cannot create %s on a read-only connection: set `read_only = false` on this '):format(
          path
        ) .. 'connection to create the database, then lock it again'
      )
      return
    end
  end

  --- Prove the connection works before the UI shows anything.
  local function probe(secret)
    self.secret = secret
    self:run('SELECT 1', {}, function(_, run_err)
      if run_err then
        on_done(false, run_err)
        return
      end
      self.connected = true
      on_done(true, nil)
    end)
  end

  if self.given_secret then
    probe(self.given_secret)
    return
  end
  connections.resolve_secret(self.spec, self.options, function(secret, err)
    if err then
      on_done(false, err)
      return
    end
    probe(secret)
  end)
end

--- Drop the secret and stop anything in flight.
function Session:close()
  self:cancel_all()
  self.secret = nil
  self.given_secret = nil
  self.connected = false
  self.catalog:clear()
  self.txn:reset()
end

function Session:cancel_all()
  for job in pairs(self.jobs) do
    job.cancel()
  end
  self.jobs = {}
end

function Session:is_busy()
  return next(self.jobs) ~= nil
end

---@class dblens.WriteApproval
---@field confirmed boolean  -- the confirmation UI (or the policy) cleared this exact statement

--- A job that is refused before a client is spawned. The callback still fires exactly once.
local function refused(message, on_done)
  on_done(nil, message, { reason = 'refused' })
  return {
    cancel = function() end,
    is_done = function()
      return true
    end,
  }
end

--- Tell the user why a LOCKED connection will not run this, and how to run it anyway.
---@param name string
---@param problem string
---@return string
local function multi_statement_refusal(name, problem)
  return (
    'connection `%s` is LOCKED, so it runs one statement at a time: found %s. '
    .. 'Unlock with `:DbLensWrite` (<leader>dw) to run more than one; writes still ask first.'
  ):format(name, problem)
end

--- The same, for a statement that reaches outside the read-only transaction entirely.
---@param name string
---@param problem string
---@return string
local function side_channel_refusal(name, problem)
  return (
    'connection `%s` is LOCKED and %s, so the read-only transaction does not cover it. '
    .. 'Unlock with `:DbLensWrite` (<leader>dw) to run it.'
  ):format(name, problem)
end

--- The one gate. Returns a refusal message, or nil when the statement may be sent.
---
--- `approval` is produced only by a caller that has already been through `refuse_write`
--- (`execute_write`, `commit`) or by the confirmation UI; without it, a statement that does not
--- classify as a read is judged by the connection's own rules.
---@param statement string
---@param approval dblens.WriteApproval?
---@return string? refusal, dblens.Statement classification
function Session:gate(statement, approval)
  assert(type(statement) == 'string', 'session:gate: expected a statement')
  local dialect = self.adapter.dialect
  local info = sqlmod.classify(statement, dialect)
  if self:is_read_only() then
    -- Checked BEFORE the classification is trusted, and without consulting it: the read-only
    -- transaction makes ONE statement unescapable, so a locked connection refuses everything it
    -- cannot prove is one. That leaves the classifier nothing to be wrong about.
    local framing = sqlmod.single_statement_problem(statement)
    if framing then
      return multi_statement_refusal(self.spec.name, framing), info
    end
    -- Defence in depth, by NAME, and deliberately not a boundary: a SECURITY DEFINER wrapper
    -- defeats it. Refused only while locked -- an unlocked connection can write with a plain
    -- INSERT, so refusing there would only break a legitimate dblink query.
    local side_channel = sqlmod.side_channel_problem(statement, dialect)
    if side_channel then
      return side_channel_refusal(self.spec.name, side_channel), info
    end
  end
  local meta = sqlmod.client_meta_problem(statement, dialect)
  if meta then
    -- Not SQL at all, so no connection setting covers it: `\!`, `.shell` and mysql's `system`
    -- run on this machine, whatever the server would have refused.
    return meta, info
  end
  if not info.write then
    return nil, info
  end
  local refusal = self:refuse_write({
    destructive = info.destructive,
    confirmed = approval ~= nil and approval.confirmed == true,
  })
  return refusal, info
end

--- What a run puts on the client's stdin.
---
--- On a read-only connection that is the adapter's read-only script, not the bare statement: the
--- server-side read-only TRANSACTION it opens is what makes read-only a guarantee rather than a
--- session setting the same run could turn off. A writable connection sends the statement as-is,
--- so the transaction the commit path builds for itself is never wrapped twice.
---@param statement string
---@return string
function Session:stdin_for(statement)
  assert(type(statement) == 'string' and statement ~= '', 'session:stdin_for: needs a statement')
  if not self:is_read_only() then
    return statement
  end
  -- The wrap only covers ONE statement, so this is the invariant `gate` exists to hold. Asserted
  -- here too: a future caller that reaches the client without the gate must fail loudly rather
  -- than send an unprovable script. On T-SQL this proves less than it looks — see the header.
  local framing = sqlmod.single_statement_problem(statement)
  assert(
    framing == nil,
    'session:stdin_for: a locked run must be one statement: ' .. tostring(framing)
  )
  local wrap = self.adapter.read_only_script
  assert(type(wrap) == 'function', 'session:stdin_for: adapter cannot open a read-only run')
  local script = wrap(statement)
  assert(
    type(script) == 'string' and script:find(statement, 1, true) ~= nil,
    'session:stdin_for: the read-only script must carry the statement'
  )
  return script
end

--- Spawn the client for an already-gated statement, registering the job before it starts.
---
--- The handle is registered BEFORE the process starts, so `cancel_all` can never miss a job that
--- called back before `exec.run` returned.
---@param spec { mode: string, stdin: string, timeout_ms: integer?, on_stdout: (fun(chunk: string): string?)? }
---@param on_result fun(result: dblens.ExecResult)
---@return dblens.Job
local function spawn(session, spec, on_result)
  local command = session.adapter.command(
    session:client_spec(),
    session.secret,
    spec.mode,
    session.options.clients
  )
  local handle = {
    cancel = function() end,
    is_done = function()
      return false
    end,
  }
  session.jobs[handle] = true

  local job = exec.run({
    argv = command.argv,
    env = command.env,
    stdin = spec.stdin,
    timeout_ms = spec.timeout_ms or session.options.timeout_ms,
    max_bytes = session.options.max_bytes,
    on_stdout = spec.on_stdout,
  }, function(result)
    session.jobs[handle] = nil
    on_result(result)
  end)

  handle.cancel, handle.is_done = job.cancel, job.is_done
  return handle
end

--- Run one statement, through the gate.
---
--- `opts.mode` selects the record protocol ('records', the default) or the client's plain text
--- output ('raw'). `opts.columns` supplies headers for a result that may come back empty.
--- `opts.approval` carries an already-cleared write.
---@param statement string
---@param opts { mode: string?, columns: string[]?, timeout_ms: integer?, approval: dblens.WriteApproval? }
---@param on_done fun(result: dblens.QueryResult?, err: string?, info: table?)
---@return dblens.Job
function Session:run(statement, opts, on_done)
  assert(type(statement) == 'string' and statement ~= '', 'session:run: needs a statement')
  assert(type(on_done) == 'function', 'session:run: on_done must be a function')
  opts = opts or {}
  local refusal, info = self:gate(statement, opts.approval)
  if refusal then
    return refused(refusal, on_done)
  end
  assert(type(info) == 'table', 'session:run: the gate must report a classification')
  local is_write = info.write
  local mode = opts.mode or 'records'

  return spawn(self, {
    mode = mode,
    stdin = self:stdin_for(statement),
    timeout_ms = opts.timeout_ms,
  }, function(result)
    -- A truncated READ still renders what arrived. A truncated WRITE does not: hitting the byte
    -- cap means the client was SIGTERM'd mid-batch, so the change's fate is unknown and calling
    -- that a success reported "committed" for a batch the server had rolled back.
    local partial_read = result.truncated and not is_write
    if not result.ok and not partial_read then
      on_done(nil, exec.format_error(result, self.adapter.label), {
        reason = result.reason,
        code = result.code,
        stderr = result.stderr,
      })
      return
    end
    if mode == 'raw' then
      on_done({
        columns = {},
        rows = {},
        malformed = 0,
        truncated = result.truncated,
        elapsed_ms = result.elapsed_ms,
        raw = result.stdout,
      }, nil)
      return
    end
    local decoded = self.adapter.decode(result.stdout, { columns = opts.columns })
    on_done({
      columns = decoded.columns,
      rows = decoded.rows,
      malformed = decoded.malformed,
      truncated = result.truncated,
      elapsed_ms = result.elapsed_ms,
      raw = result.stdout,
    }, nil)
  end)
end

--- Run ONE statement and hand its rows over as they arrive.
---
--- This is what makes an export a consistent read. ONE statement in ONE client invocation is ONE
--- server snapshot, so what the caller receives cannot be a mix of two reads of a table something
--- else is writing to; a run split across client processes has no such tie, whatever it orders by.
--- The single-statement rule is enforced here rather than assumed, for locked and unlocked
--- connections alike — it is the guarantee, not a formality.
---
--- Nothing accumulates the result, so what bounds the run is the statement's own LIMIT rather than
--- `max_bytes`. An engine whose decoder cannot frame a partial stream (mssql) buffers instead and
--- is bounded by `max_bytes`, reporting an error rather than a short result.
---
--- `on_rows` is called at least once, so a zero-row result still delivers its columns. It may
--- return a message to stop the run, which is how a failing writer stops the client. It runs in a
--- FAST EVENT context — it is the client's own output callback, which is what keeps it behind the
--- client rather than queued in front of a busy main loop — so it must not touch `vim.fn`,
--- `vim.api` or anything else that needs the main loop. Anything that does belongs in `on_done`.
---@param statement string
---@param opts { columns: string[]?, timeout_ms: integer?, on_rows: fun(columns: string[], rows: any[][]): string? }
---@param on_done fun(summary: { rows: integer, malformed: integer, elapsed_ms: number }?, err: string?)
---@return dblens.Job
function Session:stream(statement, opts, on_done)
  assert(type(statement) == 'string' and statement ~= '', 'session:stream: needs a statement')
  assert(type(opts.on_rows) == 'function', 'session:stream: on_rows must be a function')
  assert(type(on_done) == 'function', 'session:stream: on_done must be a function')
  local function stop(message)
    return refused(message, function(_, reported)
      on_done(nil, reported)
    end)
  end
  local framing = sqlmod.single_statement_problem(statement)
  if framing then
    return stop(('a streamed read must be exactly one statement: %s'):format(framing))
  end
  local refusal = self:gate(statement)
  if refusal then
    return stop(refusal)
  end

  local reader = protocol.reader({
    decode = self.adapter.decode,
    boundary = self.adapter.stream_boundary,
    columns = opts.columns,
    max_buffer = self.options.max_bytes,
  })
  local delivered = 0

  --- Hand on what the reader produced. An empty batch is not delivered: the columns a caller
  --- latches must come from the header the client sent, not from the catalog list seeded as a
  --- fallback, which a schema change since the last load would have made stale.
  local function deliver(rows, err)
    if err then
      return err
    end
    if #rows == 0 then
      return nil
    end
    delivered = delivered + #rows
    return opts.on_rows(reader.columns(), rows)
  end

  return spawn(self, {
    mode = 'records',
    stdin = self:stdin_for(statement),
    timeout_ms = opts.timeout_ms,
    on_stdout = function(chunk)
      return deliver(reader.push(chunk))
    end,
  }, function(result)
    if not result.ok then
      on_done(nil, exec.format_error(result, self.adapter.label))
      return
    end
    local tail_err = deliver(reader.finish())
    if tail_err then
      on_done(nil, tail_err)
      return
    end
    -- A result with no rows at all still has columns, and a caller writing a file needs them for
    -- its header, so it is told once rather than left to guess from an empty run.
    if delivered == 0 then
      local empty_err = opts.on_rows(reader.columns(), {})
      if empty_err then
        on_done(nil, empty_err)
        return
      end
    end
    on_done({
      rows = delivered,
      malformed = reader.malformed(),
      elapsed_ms = result.elapsed_ms,
    }, nil)
  end)
end

--- Run statements in order, stopping at the first failure.
---
--- Reports every statement's outcome so the query runner can show per-statement timing. The
--- returned handle is what makes an editor query cancellable: it stops the client that is
--- running now AND keeps the script from starting the next statement.
---@param statements string[]
---@param opts { approval: dblens.WriteApproval? }?
---@param on_done fun(outcomes: { sql: string, result: dblens.QueryResult?, err: string? }[])
---@return dblens.Job
function Session:run_script(statements, opts, on_done)
  assert(vim.islist(statements) and #statements > 0, 'session:run_script: needs statements')
  assert(type(on_done) == 'function', 'session:run_script: on_done must be a function')
  opts = opts or {}
  local outcomes, cancelled, current = {}, false, nil

  local function step(index)
    if index > #statements or cancelled then
      on_done(outcomes)
      return
    end
    current = self:run(statements[index], { approval = opts.approval }, function(result, err)
      outcomes[#outcomes + 1] = { sql = statements[index], result = result, err = err }
      if err or cancelled then
        on_done(outcomes)
        return
      end
      step(index + 1)
    end)
  end
  step(1)

  return {
    cancel = function()
      cancelled = true
      if current then
        current.cancel()
      end
    end,
    is_done = function()
      return current == nil or current.is_done()
    end,
  }
end

---@class dblens.WriteRequest
---@field sql string
---@field summary string
---@field destructive boolean
---@field guard string?     -- count(*) that must return exactly 1
---@field confirmed boolean -- set only by the confirmation UI
---@field change dblens.PendingChange?  -- carried into the transaction queue

local function guard_count(result)
  local first = result.rows[1]
  if not first then
    return nil
  end
  return tonumber(protocol.tostring(first[1]))
end

--- Refuse a write for a reason that does not depend on the database.
---@return string? refusal
function Session:refuse_write(request)
  if self:is_read_only() then
    return ('connection `%s` is read-only'):format(self.spec.name)
  end
  local needs_confirmation = (request.destructive and self.options.safety.confirm_destructive)
    or (not request.destructive and self.options.safety.confirm_write)
  if needs_confirmation and not request.confirmed then
    return 'this change was not confirmed'
  end
  return nil
end

--- Apply a write, or queue it when transaction mode is on.
---
---@param request dblens.WriteRequest
---@param on_done fun(outcome: { queued: boolean, affected: integer? }?, err: string?)
function Session:execute_write(request, on_done)
  assert(type(request.sql) == 'string' and request.sql ~= '', 'session:execute_write: needs SQL')
  assert(type(on_done) == 'function', 'session:execute_write: on_done must be a function')

  local refusal = self:refuse_write(request)
  if refusal then
    on_done(nil, refusal)
    return
  end

  local approval = { confirmed = request.confirmed == true }

  local function proceed()
    if self.txn:is_active() then
      local change = request.change or { sql = request.sql, summary = request.summary }
      -- The guard rides into the queue so commit can re-check it inside the transaction.
      change.guard = change.guard or request.guard
      self.txn:add(change)
      on_done({ queued = true }, nil)
      return
    end
    self:run(self:with_affected(request.sql), { approval = approval }, function(result, err)
      if err then
        on_done(nil, err)
        return
      end
      on_done({ queued = false, affected = self:read_affected(result) }, nil)
    end)
  end

  if not request.guard then
    proceed()
    return
  end
  self:run(request.guard, {}, function(result, err)
    if err then
      on_done(nil, ('could not verify the target row: %s'):format(err))
      return
    end
    local count = guard_count(result)
    if count ~= 1 then
      on_done(
        nil,
        ('refusing to apply: the row predicate matches %s rows, not exactly 1'):format(
          count or 'an unknown number of'
        )
      )
      return
    end
    proceed()
  end)
end

--- Append the adapter's affected-rows query to a write.
---
--- `changes()` / `ROW_COUNT()` report on the *client session*, and every call spawns a fresh
--- client process, so asking afterwards would always answer 0. They must ride along in the same
--- invocation. A write produces no rows of its own, so the only output is the count.
---@return string
function Session:with_affected(statement)
  local affected = self.adapter.sql.affected and self.adapter.sql.affected()
  if not affected then
    return statement
  end
  return statement .. ';\n' .. affected
end

--- Affected-row count from a `with_affected` result, or nil when the adapter cannot report one.
---@return integer?
function Session:read_affected(result)
  if not (self.adapter.sql.affected and self.adapter.sql.affected()) then
    return nil
  end
  local first = result.rows[1]
  if not first then
    return nil
  end
  return tonumber(protocol.tostring(first[1]))
end

--- Kill reasons that leave the batch's fate unknown: the client was stopped mid-script, so the
--- COMMIT may or may not have run. A `spawn` failure is not one of them — nothing ran.
local KILLED = { timeout = true, cancelled = true, max_bytes = true }

--- Name the queued change a client blamed, using the line it reported.
---@return string
local function describe_failure(owners, info, total, run_err)
  local line = info and info.stderr and exec.error_line(info.stderr) or nil
  local owner = line and owners[line] or nil
  if not owner then
    return ('the batch failed and was rolled back: %s'):format(run_err)
  end
  if owner.guard then
    return ('change %d of %d no longer matches exactly one row, so nothing was applied'):format(
      owner.index,
      total
    )
  end
  return ('change %d of %d failed, so nothing was applied: %s'):format(owner.index, total, run_err)
end

--- Commit the queued batch as one atomic script.
---
--- On failure the queue is kept ONLY when the client is known to have aborted the batch itself
--- (a statement error under `-bail`/`ON_ERROR_STOP=1`, so nothing committed). If dblens killed
--- the client instead, the outcome is unknown and the queue is dropped: replaying it could
--- apply a committed INSERT twice, or re-run a DELETE whose guard has already been spent.
---@param on_done fun(ok: boolean, err: string?, queue_kept: boolean)
function Session:commit(on_done)
  assert(type(on_done) == 'function', 'session:commit: on_done must be a function')
  if self:is_read_only() then
    on_done(false, ('connection `%s` is read-only'):format(self.spec.name), true)
    return
  end
  local assert_one = self.adapter.sql.assert_one
  assert(type(assert_one) == 'function', 'session:commit: adapter has no row-guard builder')
  local batch_frame = self.adapter.sql.batch_frame
  assert(type(batch_frame) == 'function', 'session:commit: adapter has no transaction frame')
  local script, err, owners = self.txn:script(assert_one, batch_frame())
  if not script then
    on_done(false, err, true)
    return
  end

  local total = self.txn:count()
  self:run(script, { approval = { confirmed = true } }, function(_, run_err, info)
    -- Checked BEFORE success: a killed client can exit 0 on its own, and treating that as a
    -- landed commit both lied to the user and cleared changes the server had rolled back.
    if info and KILLED[info.reason] then
      self.txn:reset()
      on_done(
        false,
        (
          'the commit was interrupted (%s); the queue was discarded because it is not known '
          .. 'whether it landed - verify the table before changing it again'
        ):format(info.reason),
        false
      )
      return
    end
    if not run_err then
      self.txn:reset()
      on_done(true, nil, false)
      return
    end
    on_done(false, describe_failure(owners, info, total, run_err), true)
  end)
end

--- Estimate how many rows a destructive statement would touch, without running it.
---@param statement string
---@param on_done fun(estimate: integer?, err: string?)
function Session:estimate(statement, on_done)
  if not self.adapter.estimate then
    on_done(nil, nil)
    return
  end
  local plan = self.adapter.estimate(statement)
  self:run(plan.sql, { mode = plan.mode }, function(result, err)
    if err then
      on_done(nil, err)
      return
    end
    on_done(plan.parse(result, result.raw), nil)
  end)
end

M.Session = Session
return M
