--- Pretty-printing SQL by handing it to a real formatter.
---
--- dblens does not format SQL itself. A hand-rolled Lua formatter would be a second, worse parser
--- of a language with six dialects, and it would be wrong exactly where it matters; the formatters
--- below already exist and are already installed on the machines that care.
---
--- The formatter never EXECUTES anything. It is spawned from an argv array — no shell, no `-c`,
--- nothing that reads the text as a command — the SQL arrives on its stdin as data, and what comes
--- back on stdout is text that replaces a buffer. No connection, no client and no database is
--- involved, so this path exists entirely outside the read-only gate rather than around it.
local exec = require('dblens.exec')

local M = {}

--- Tried in this order, each with the flags that make it read stdin and write stdout.
---
--- `--dialect ansi` is passed to sqlfluff because it refuses to run without one; a project that
--- wants its own dialect (or a different formatter entirely) sets `format.command`.
M.CANDIDATES = {
  { 'sqlfluff', 'format', '--dialect', 'ansi', '-' },
  { 'pg_format', '-' },
  { 'sqlformat', '--reindent', '-' },
}

--- What to install, named in the order they are tried.
---@return string
local function nothing_found()
  local names = {}
  for _, candidate in ipairs(M.CANDIDATES) do
    names[#names + 1] = '`' .. candidate[1] .. '`'
  end
  return ('no SQL formatter found - install one of %s, or set `format.command`'):format(
    table.concat(names, ', ')
  )
end

--- The formatter to run: the configured one, or the first candidate that is installed.
---@param configured string[]?  -- `format.command`; empty or nil means detect one
---@return string[]? argv, string? error
function M.detect(configured)
  assert(configured == nil or vim.islist(configured), 'format.detect: command must be an argv list')
  if configured and #configured > 0 then
    if vim.fn.executable(configured[1]) ~= 1 then
      return nil, ('`%s` (format.command) was not found on PATH'):format(configured[1])
    end
    return configured, nil
  end
  for _, candidate in ipairs(M.CANDIDATES) do
    if vim.fn.executable(candidate[1]) == 1 then
      return candidate, nil
    end
  end
  return nil, nothing_found()
end

--- Format SQL text.
---
--- `on_done` is called exactly once, with the formatted text or with a reason. A formatter that
--- fails, times out or returns nothing is an error: the caller must leave the buffer alone rather
--- than replace a statement with whatever came back.
---@param text string
---@param options table  resolved config
---@param on_done fun(formatted: string?, err: string?)
---@return dblens.Job?  -- nil when nothing was started
function M.run(text, options, on_done)
  assert(type(text) == 'string', 'format.run: expected the text to format')
  assert(type(on_done) == 'function', 'format.run: on_done must be a function')
  assert(type(options) == 'table' and options.format, 'format.run: needs resolved options')
  if vim.trim(text) == '' then
    on_done(nil, 'nothing to format')
    return nil
  end
  local argv, err = M.detect(options.format.command)
  if not argv then
    on_done(nil, err)
    return nil
  end

  local label = argv[1]
  return exec.run({
    argv = argv,
    stdin = text,
    timeout_ms = options.timeout_ms,
    max_bytes = options.max_bytes,
  }, function(result)
    if not result.ok then
      on_done(nil, exec.format_error(result, label))
      return
    end
    if vim.trim(result.stdout) == '' then
      -- Replacing a statement with nothing is the one outcome worse than not formatting it.
      on_done(nil, ('%s returned nothing, so the buffer was left alone'):format(label))
      return
    end
    on_done(result.stdout, nil)
  end)
end

return M
