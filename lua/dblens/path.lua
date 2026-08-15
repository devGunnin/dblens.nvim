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
---
--- This validates external input, so every rejection is a returned error, never a raise: the
--- caller chain up to `:DbLens` is not wrapped, and a bad connections file must name its problem
--- rather than take the plugin down with a traceback.
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
  if raw:find('$(', 1, true) then
    -- The one form that looks like command substitution; nothing here would evaluate it, but a
    -- path that reads as a command is a mistake worth naming rather than opening as a file.
    return nil, ('path must not contain `$(`: %s'):format(raw)
  end
  if raw:sub(1, 1) == '~' and raw ~= '~' and raw:sub(2, 2) ~= '/' then
    -- `vim.fs.normalize` rewrites a leading `~` whatever follows, so `~root/db` silently became
    -- `<current-user-home>root/db` and opened (or created) the wrong file.
    return nil, ('path must not use `~user`; only `~/` is expanded: %s'):format(raw)
  end

  local expanded = vim.fs.normalize((raw:gsub('%${([%w_]+)}', '$%1')))
  local unset = expanded:match('%$([%w_]+)')
  if unset then
    return nil, ('path refers to $%s, which is not set: %s'):format(unset, raw)
  end
  -- Reported against `raw`: the expansion holds environment values that may be secrets.
  if expanded:find('`', 1, true) then
    return nil, ('path expands to a value containing a backtick: %s'):format(raw)
  end
  if expanded == '' then
    return nil, ('path expands to nothing: %s'):format(raw)
  end
  if expanded:sub(1, 1) == '-' then
    -- The raw check above is not enough: `$DIR/x.db` with `DIR=--evil` expands into an option.
    -- sqlite3 and duckdb take the file as a bare positional and have no end-of-options form.
    return nil, ('path expands to a value starting with `-`: %s'):format(raw)
  end
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
