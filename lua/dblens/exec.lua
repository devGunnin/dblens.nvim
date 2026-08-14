--- Async client-process execution: streaming output cap, timeout, and cancellation.
---
--- Every database call in dblens goes through here. Nothing blocks the UI, and the process has
--- exactly one termination path (`stop`) with three reasons, so a killed job can always say why.
local M = {}

local uv = vim.uv or vim.loop

---@class dblens.ExecResult
---@field ok boolean
---@field code integer
---@field stdout string
---@field stderr string
---@field truncated boolean    -- output hit `max_bytes` and the client was killed
---@field reason string?       -- 'timeout' | 'cancelled' | 'max_bytes' | 'spawn'
---@field elapsed_ms number

---@class dblens.Job
---@field cancel fun()
---@field is_done fun(): boolean

---@class dblens.ExecSpec
---@field argv string[]
---@field env table<string, string>?  -- merged over the editor environment; carries secrets
---@field stdin string?
---@field timeout_ms integer
---@field max_bytes integer

local function fail_fast(message, on_done)
  vim.schedule(function()
    on_done({
      ok = false,
      code = -1,
      stdout = '',
      stderr = message,
      truncated = false,
      reason = 'spawn',
      elapsed_ms = 0,
    })
  end)
  return {
    cancel = function() end,
    is_done = function()
      return true
    end,
  }
end

--- Collector for one stream, capping total bytes.
local function new_sink(limit, on_overflow)
  local parts, size, overflowed = {}, 0, false
  return {
    push = function(chunk)
      if overflowed or not chunk then
        return
      end
      size = size + #chunk
      parts[#parts + 1] = chunk
      if size > limit then
        overflowed = true
        on_overflow()
      end
    end,
    text = function()
      return table.concat(parts)
    end,
    overflowed = function()
      return overflowed
    end,
  }
end

--- Run a client process.
---
--- `on_done` is always called exactly once, on the main loop, including on spawn failure.
---@param spec dblens.ExecSpec
---@param on_done fun(result: dblens.ExecResult)
---@return dblens.Job
function M.run(spec, on_done)
  assert(type(spec.argv) == 'table' and #spec.argv > 0, 'exec.run: argv must be non-empty')
  assert(type(on_done) == 'function', 'exec.run: on_done must be a function')
  assert(
    spec.timeout_ms > 0 and spec.max_bytes > 0,
    'exec.run: timeout and byte cap must be positive'
  )

  local client = spec.argv[1]
  if vim.fn.executable(client) ~= 1 then
    return fail_fast(('client `%s` was not found on PATH'):format(client), on_done)
  end

  local started = uv.hrtime()
  local handle, timer, kill_timer, finished, reason
  --- SIGTERM, then SIGKILL if the client ignores it: without the escalation a stuck client
  --- leaves the UI busy forever with no way back, because `complete` never runs.
  local function stop(why)
    if finished or not handle then
      return
    end
    reason = reason or why
    handle:kill('sigterm')
    if kill_timer then
      return
    end
    kill_timer = uv.new_timer()
    kill_timer:start(2000, 0, function()
      if not finished and handle then
        pcall(handle.kill, handle, 'sigkill')
      end
    end)
  end

  -- stderr is capped too: a client stuck in a message loop must not grow without bound.
  local stdout = new_sink(spec.max_bytes, function()
    stop('max_bytes')
  end)
  local stderr = new_sink(math.min(spec.max_bytes, 1024 * 1024), function()
    stop('max_bytes')
  end)

  local function complete(res)
    if finished then
      return
    end
    finished = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if kill_timer then
      kill_timer:stop()
      kill_timer:close()
      kill_timer = nil
    end
    -- A timeout that fires while the exit callback is already queued must not turn a finished,
    -- successful run into "timed out": the output is complete and the exit code is real.
    if reason == 'timeout' and res.code == 0 then
      reason = nil
    end
    local elapsed_ms = (uv.hrtime() - started) / 1e6
    on_done({
      ok = res.code == 0 and reason == nil,
      code = res.code,
      stdout = stdout.text(),
      stderr = stderr.text(),
      truncated = stdout.overflowed(),
      reason = reason,
      elapsed_ms = elapsed_ms,
    })
  end

  local spawned, err = pcall(function()
    -- `text = false`: text mode rewrites CRLF to LF in the collected output, and that lands on
    -- the raw record stream, so any cell holding a CRLF came back altered.
    handle = vim.system(spec.argv, {
      env = spec.env,
      stdin = spec.stdin,
      text = false,
      stdout = function(_, data)
        stdout.push(data)
      end,
      stderr = function(_, data)
        stderr.push(data)
      end,
    }, function(res)
      vim.schedule(function()
        complete(res)
      end)
    end)
  end)
  if not spawned then
    return fail_fast(('could not start `%s`: %s'):format(client, err), on_done)
  end

  timer = uv.new_timer()
  timer:start(spec.timeout_ms, 0, function()
    stop('timeout')
  end)

  return {
    cancel = function()
      stop('cancelled')
    end,
    is_done = function()
      return finished == true
    end,
  }
end

--- Turn a failed result into one actionable line, never a stack trace.
---
--- Client stderr is the useful part; the reason explains a zero-output kill.
---@param result dblens.ExecResult
---@param label string  -- what was being run, e.g. 'sqlite3'
---@return string
function M.format_error(result, label)
  assert(type(result) == 'table', 'exec.format_error: expected a result')
  if result.reason == 'timeout' then
    return ('%s: timed out'):format(label)
  end
  if result.reason == 'cancelled' then
    return ('%s: cancelled'):format(label)
  end
  if result.reason == 'max_bytes' then
    -- Not "truncated": the client was killed mid-run, so anything it had not finished is unknown.
    return ('%s: output limit reached, the client was stopped'):format(label)
  end
  local message = vim.trim(result.stderr)
  if message == '' then
    message = ('exited with code %d'):format(result.code)
  end
  -- Clients prefix their own name and repeat it per line; keep the first meaningful line.
  local first = message:gmatch('[^\r\n]+')()
  return ('%s: %s'):format(label, vim.trim(first or message))
end

--- The script line a client blamed for a failure, or nil.
---
--- Each client says it differently, and this is the only way to trace a failure inside a batch
--- back to the statement that caused it: `sqlite3` "near line 3", `psql:<stdin>:3:`, mysql/mariadb
--- "at line 3", sqlcmd "Msg 208, ..., Line 3".
---
--- duckdb is deliberately absent: its `LINE 1:` counts from the start of the failing STATEMENT,
--- not the script (verified), so reading it would blame the wrong queued change.
---@param stderr string
---@return integer?
function M.error_line(stderr)
  assert(type(stderr) == 'string', 'exec.error_line: expected a string')
  local line = stderr:match('near line (%d+)')
    or stderr:match('psql:[^:\n]*:(%d+):')
    or stderr:match(' at line (%d+)')
    or stderr:match('Msg %d+, Level %d+, State %d+[^\n]*, Line (%d+)')
  return line and tonumber(line) or nil
end

return M
