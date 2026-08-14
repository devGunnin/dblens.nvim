--- A live connection: its adapter, its resolved secret, its schema cache, its transaction.
---
--- EVERY statement dblens sends — a browsed page, a filter, ad-hoc editor SQL, EXPLAIN, a CRUD
--- write, a committed batch — goes through `Session:run`, and `run` puts every one of them
--- through `Session:gate` first. That is the whole safety model: read-only, the destructive
--- confirmation and the refusal of client meta-commands are enforced at one choke point, not in
--- whichever part of the UI happened to ask.
---
--- The gate fails CLOSED. `sql.classify` only reports a read when it can prove one, so an
--- unrecognised verb, a stacked script or an EXPLAIN ANALYZE is treated as a write and refused
--- on a read-only connection rather than waved through.
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
  }, Session),
    nil
end

function Session:is_read_only()
  return self.spec.read_only == true
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

--- The one gate. Returns a refusal message, or nil when the statement may be sent.
---
--- `approval` is produced only by a caller that has already been through `refuse_write`
--- (`execute_write`, `commit`) or by the confirmation UI; without it, a statement that is not
--- provably a read is judged by the connection's own rules.
---@param statement string
---@param approval dblens.WriteApproval?
---@return string? refusal
function Session:gate(statement, approval)
  assert(type(statement) == 'string', 'session:gate: expected a statement')
  local dialect = self.adapter.dialect
  local meta = sqlmod.client_meta_problem(statement, dialect)
  if meta then
    -- Not SQL at all, so no connection flag covers it: `\!` and `.shell` run on this machine.
    return meta
  end
  local info = sqlmod.classify(statement, dialect)
  if not info.write then
    return nil
  end
  return self:refuse_write({
    destructive = info.destructive,
    confirmed = approval ~= nil and approval.confirmed == true,
  })
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
  local refusal = self:gate(statement, opts.approval)
  if refusal then
    return refused(refusal, on_done)
  end

  local mode = opts.mode or 'records'
  local command = self.adapter.command(self.spec, self.secret, mode, self.options.clients)

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
    stdin = statement,
    timeout_ms = opts.timeout_ms or self.options.timeout_ms,
    max_bytes = self.options.max_bytes,
  }, function(result)
    self.jobs[handle] = nil
    if not result.ok and not result.truncated then
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
    if not run_err then
      self.txn:reset()
      on_done(true, nil, false)
      return
    end
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
