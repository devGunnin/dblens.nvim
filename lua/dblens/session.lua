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
--- What makes a LOCKED connection read-only is TWO things, and neither is the classifier:
---  * the SERVER — the run is sent inside a read-only TRANSACTION (`adapter.read_only_script`)
---    over a connection opened read-only (`adapter.command`). No `SET` in the same run escapes
---    it; sqlite needs none, its `-readonly` is the file open mode. That holds for ONE statement.
---  * the ONE-STATEMENT rule — postgres and mysql let a SECOND statement end or replace that
---    transaction and write in a fresh one, so a locked connection refuses any input
---    `sql.single_statement_problem` cannot prove is exactly one. It is a byte scan, so unlike
---    the four lexer generations before it there is no dialect it can be wrong about.
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
---@return dblens.Session? session, string? error
function M.new(spec, options)
  local adapter, err = adapters.get(spec.kind)
  if not adapter then
    return nil, err
  end
  return setmetatable({
    spec = spec,
    adapter = adapter,
    options = options,
    catalog = catalog.new(adapter.caps.schemas),
    txn = txn.new(),
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

--- The one label for the connection's mode. LOCKED means the server refuses every write.
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
  if self.spec.kind == 'sqlite' and not self.spec.create then
    local path, path_err = path_mod.expand(self.spec.path)
    if not path then
      on_done(false, path_err)
      return
    end
    if vim.fn.filereadable(path) == 0 then
      -- sqlite3 silently creates a missing file; a typo would open an empty database.
      on_done(false, ('no such database file: %s (set `create = true` to make it)'):format(path))
      return
    end
  end

  connections.resolve_secret(self.spec, self.options, function(secret, err)
    if err then
      on_done(false, err)
      return
    end
    self.secret = secret
    self:run('SELECT 1', {}, function(_, run_err)
      if run_err then
        on_done(false, run_err)
        return
      end
      self.connected = true
      on_done(true, nil)
    end)
  end)
end

--- Drop the secret and stop anything in flight.
function Session:close()
  self:cancel_all()
  self.secret = nil
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
  -- The wrap only guarantees read-only for ONE statement, so this is the invariant `gate` exists
  -- to hold. Asserted here too: a future caller that reaches the client without the gate must
  -- fail loudly rather than send an unprovable script.
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
  local command = self.adapter.command(self:client_spec(), self.secret, mode, self.options.clients)
  local stdin = self:stdin_for(statement)

  -- The handle is registered BEFORE the process starts, so `cancel_all` can never miss a job
  -- that called back before `exec.run` returned.
  local handle = {
    cancel = function() end,
    is_done = function()
      return false
    end,
  }
  self.jobs[handle] = true

  local job = exec.run({
    argv = command.argv,
    env = command.env,
    stdin = stdin,
    timeout_ms = opts.timeout_ms or self.options.timeout_ms,
    max_bytes = self.options.max_bytes,
  }, function(result)
    self.jobs[handle] = nil
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

  handle.cancel, handle.is_done = job.cancel, job.is_done
  return handle
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
  local script, err, owners = self.txn:script(assert_one)
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
