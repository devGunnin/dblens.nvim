--- A live connection: its adapter, its resolved secret, its schema cache, its transaction.
---
--- Every database call in dblens goes through `run`, and every *write* goes through
--- `execute_write`. That single choke point is what enforces the safety model: a read-only
--- connection, an unconfirmed destructive statement, and a predicate that does not match exactly
--- one row are all refused here, not in the UI that happened to ask.
local adapters = require('dblens.adapters')
local catalog = require('dblens.catalog')
local connections = require('dblens.connections')
local exec = require('dblens.exec')
local protocol = require('dblens.protocol')
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
  }, Session), nil
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
    local path = vim.fn.expand(self.spec.path)
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

--- Run one statement.
---
--- `opts.mode` selects the record protocol ('records', the default) or the client's plain text
--- output ('raw'). `opts.columns` supplies headers for a result that may come back empty.
---@param statement string
---@param opts { mode: string?, columns: string[]?, timeout_ms: integer? }
---@param on_done fun(result: dblens.QueryResult?, err: string?)
---@return dblens.Job
function Session:run(statement, opts, on_done)
  assert(type(statement) == 'string' and statement ~= '', 'session:run: needs a statement')
  assert(type(on_done) == 'function', 'session:run: on_done must be a function')
  opts = opts or {}
  local mode = opts.mode or 'records'
  local command = self.adapter.command(self.spec, self.secret, mode, self.options.clients)

  local job
  job = exec.run({
    argv = command.argv,
    env = command.env,
    stdin = statement,
    timeout_ms = opts.timeout_ms or self.options.timeout_ms,
    max_bytes = self.options.max_bytes,
  }, function(result)
    self.jobs[job] = nil
    if not result.ok and not result.truncated then
      on_done(nil, exec.format_error(result, self.adapter.label))
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

  self.jobs[job] = true
  return job
end

--- Run statements in order, stopping at the first failure.
---
--- Reports every statement's outcome so the query runner can show per-statement timing, and
--- returns the last result that actually produced columns.
---@param statements string[]
---@param on_done fun(outcomes: { sql: string, result: dblens.QueryResult?, err: string? }[])
function Session:run_script(statements, on_done)
  assert(vim.islist(statements) and #statements > 0, 'session:run_script: needs statements')
  local outcomes = {}
  local function step(index)
    if index > #statements then
      on_done(outcomes)
      return
    end
    self:run(statements[index], {}, function(result, err)
      outcomes[#outcomes + 1] = { sql = statements[index], result = result, err = err }
      if err then
        on_done(outcomes)
        return
      end
      step(index + 1)
    end)
  end
  step(1)
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

  local function proceed()
    if self.txn:is_active() then
      self.txn:add(request.change or { sql = request.sql, summary = request.summary })
      on_done({ queued = true }, nil)
      return
    end
    self:run(self:with_affected(request.sql), {}, function(result, err)
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
      on_done(nil, ('refusing to apply: the row predicate matches %s rows, not exactly 1'):format(count or 'an unknown number of'))
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

--- Commit the queued batch as one atomic script.
---@param on_done fun(ok: boolean, err: string?)
function Session:commit(on_done)
  local script, err = self.txn:script()
  if not script then
    on_done(false, err)
    return
  end
  if self:is_read_only() then
    on_done(false, ('connection `%s` is read-only'):format(self.spec.name))
    return
  end
  self:run(script, {}, function(_, run_err)
    if run_err then
      -- The batch is wrapped in BEGIN/COMMIT, so a failure left nothing behind; keep the queue
      -- so the user can fix and retry.
      on_done(false, run_err)
      return
    end
    self.txn:reset()
    on_done(true, nil)
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
