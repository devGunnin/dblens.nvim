--- Session restore: remember the last connection and open table, and put them back on request.
---
--- Restoring reconnects to a database, so it never happens implicitly at startup. It runs on
--- `:DbLensRestore`, or on open when `session.restore` is switched on.
local M = {}

local function read(path)
  local file = io.open(path, 'r')
  if not file then
    return nil, nil
  end
  local text = file:read('*a')
  file:close()
  if vim.trim(text) == '' then
    return nil, nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return nil, ('%s is not valid JSON: %s'):format(path, decoded)
  end
  if type(decoded) ~= 'table' then
    return nil, ('%s does not contain a session object'):format(path)
  end
  return decoded, nil
end

---@class dblens.SavedSession
---@field connection string?
---@field schema string?
---@field relation string?

--- Persist what is currently open.
---@param options table
---@param snapshot dblens.SavedSession
---@return boolean ok, string? error
function M.save(options, snapshot)
  assert(type(snapshot) == 'table', 'state.save: expected a snapshot table')
  local path = options.state_file
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, 'p') == 0 then
    return false, ('could not create %s'):format(dir)
  end
  local file, err = io.open(path, 'w')
  if not file then
    return false, ('could not write %s: %s'):format(path, err)
  end
  file:write(vim.json.encode(snapshot))
  file:close()
  return true, nil
end

--- Read the last saved session.
---@return dblens.SavedSession?, string? error
function M.load(options)
  return read(options.state_file)
end

--- Snapshot the live UI. Returns nil when nothing is worth remembering.
---@param state dblens.State
---@return dblens.SavedSession?
function M.snapshot(state)
  if not state or not state.session then
    return nil
  end
  -- A discovered connection exists only for the session that found it, so remembering its name
  -- would restore into "the saved connection no longer exists" on the next start.
  if state.session.spec.source == 'discovered' then
    return nil
  end
  local source = state.grid.source
  local relation = source and source.kind == 'relation' and source.relation or nil
  return {
    connection = state.session.spec.name,
    schema = relation and relation.schema or nil,
    relation = relation and relation.name or nil,
  }
end

return M
