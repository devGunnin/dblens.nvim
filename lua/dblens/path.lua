--- Filesystem paths that arrive from a connections file, a spec or a prompt.
---
--- `vim.fn.expand` is the wrong tool for these: its wildcard expansion includes backtick command
--- substitution, so expanding an attacker-supplied path RUNS IT through the shell. Nothing here
--- evaluates anything — `~` and `$VAR` are substituted textually and everything else is rejected.
local M = {}

--- Characters that would either be evaluated by an expander or misread by a client.
local REJECT = {
  ['`'] = 'a backtick',
  ['*'] = 'a `*` wildcard',
  ['?'] = 'a `?` wildcard',
  ['\n'] = 'a newline',
  ['\r'] = 'a carriage return',
  ['\0'] = 'a NUL byte',
}

--- Expand `~` and `$VAR` in a path, without any shell or command evaluation.
---@param raw string
---@return string? path, string? error
function M.expand(raw)
  if type(raw) ~= 'string' or raw == '' then
    return nil, 'path must be a non-empty string'
  end
  for char, what in pairs(REJECT) do
    if raw:find(char, 1, true) then
      return nil, ('path must not contain %s: %s'):format(what, raw)
    end
  end
  if raw:sub(1, 1) == '-' then
    -- Every client dblens spawns would read this as an option rather than a filename.
    return nil, ('path must not start with `-`: %s'):format(raw)
  end

  local expanded = vim.fs.normalize((raw:gsub('%${([%w_]+)}', '$%1')))
  local unset = expanded:match('%$([%w_]+)')
  if unset then
    return nil, ('path refers to $%s, which is not set: %s'):format(unset, raw)
  end
  assert(not expanded:find('`', 1, true), 'path.expand: expansion reintroduced a backtick')
  assert(expanded ~= '', 'path.expand: expansion produced an empty path')
  return expanded, nil
end

--- Expand a path that has already passed validation at the boundary.
---
--- Callers that hold a validated spec cannot act on an error here, so a failure is a bug in the
--- validation path rather than bad user input, and must be loud.
---@param raw string
---@param where string  -- caller, for the assertion message
---@return string
function M.expand_validated(raw, where)
  local path, err = M.expand(raw)
  assert(path, ('%s: %s'):format(where, tostring(err)))
  return path
end

return M
