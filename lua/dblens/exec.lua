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

local function fail_fast(spec, message, on_done)
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
  return { cancel = function() end, is_done = function()
    return true
  end }
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
  assert(spec.timeout_ms > 0 and spec.max_bytes > 0, 'exec.run: timeout and byte cap must be positive')

  local client = spec.argv[1]
  if vim.fn.executable(client) ~= 1 then
    return fail_fast(spec, ('client `%s` was not found on PATH'):format(client), on_done)
  end

  local started = uv.hrtime()
  local handle, timer, finished, reason
  local function stop(why)
    if finished or not handle then
      return
    end
    reason = reason or why
    handle:kill('sigterm')
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
    handle = vim.system(spec.argv, {
      env = spec.env,
      stdin = spec.stdin,
      text = true,
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
    return fail_fast(spec, ('could not start `%s`: %s'):format(client, err), on_done)
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
    return ('%s: output limit reached, result truncated'):format(label)
  end
  local message = vim.trim(result.stderr)
  if message == '' then
    message = ('exited with code %d'):format(result.code)
  end
  -- Clients prefix their own name and repeat it per line; keep the first meaningful line.
  local first = message:gmatch('[^\n]+')()
  return ('%s: %s'):format(label, first or message)
end

return M
