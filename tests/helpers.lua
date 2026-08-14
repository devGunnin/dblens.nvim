--- Helpers shared by the specs. `tests/minit.lua` puts `tests/` on `package.path`, so a spec
--- reaches this with `require('helpers')`.
local MiniTest = require('mini.test')

local M = {}

M.eq = MiniTest.expect.equality
M.neq = MiniTest.expect.no_equality
M.expect_error = MiniTest.expect.error
M.expect_no_error = MiniTest.expect.no_error

--- SQL NULL, as `dblens.protocol` represents it in a decoded row.
M.NULL = vim.NIL

M.FIELD_SEP = '\031'
M.RECORD_SEP = '\030'
M.NULL_SENTINEL = '\029'

--- One wire record: fields joined by the field separator.
---@param ... string
---@return string
function M.record(...)
  local fields = { ... }
  assert(select('#', ...) > 0, 'helpers.record: a record has at least one field')
  for i, field in ipairs(fields) do
    assert(type(field) == 'string', ('helpers.record: field %d must be a string'):format(i))
  end
  return table.concat(fields, M.FIELD_SEP)
end

--- Client stdout: records joined by, and terminated with, the record separator -- exactly what
--- psql `-R` and sqlite `-ascii` emit, trailing separator included.
---@param records string[]
---@return string
function M.wire(records)
  assert(type(records) == 'table', 'helpers.wire: expected a list of records')
  if #records == 0 then
    return ''
  end
  return table.concat(records, M.RECORD_SEP) .. M.RECORD_SEP
end

--- The argv entry following `flag`, or nil when the flag is absent.
---@param argv string[]
---@param flag string
---@return string?
function M.flag_value(argv, flag)
  assert(type(argv) == 'table' and #argv > 0, 'helpers.flag_value: argv must be non-empty')
  assert(type(flag) == 'string' and flag ~= '', 'helpers.flag_value: flag must be a string')
  for i, entry in ipairs(argv) do
    if entry == flag then
      return argv[i + 1]
    end
  end
  return nil
end

--- Whether `value` appears in `list`.
---@param list any[]
---@param value any
---@return boolean
function M.has(list, value)
  assert(type(list) == 'table', 'helpers.has: expected a list')
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

--- Every string reachable from `value`, keys included. Depth-capped: the structures under test
--- are small and shallow, and a cycle must fail loudly rather than spin.
---@param value any
---@param out string[]?
---@param depth integer?
---@return string[]
function M.strings(value, out, depth)
  out, depth = out or {}, depth or 0
  assert(depth < 8, 'helpers.strings: structure is deeper than expected (cycle?)')
  if type(value) == 'string' then
    out[#out + 1] = value
  elseif type(value) == 'table' then
    for key, entry in pairs(value) do
      M.strings(key, out, depth + 1)
      M.strings(entry, out, depth + 1)
    end
  end
  return out
end

--- A freshly loaded copy of `name`, leaving the already-loaded one in place. Lets a spec see a
--- module in its untouched, never-configured state.
---@param name string
---@return table
function M.fresh_module(name)
  assert(type(name) == 'string' and name ~= '', 'helpers.fresh_module: expected a module name')
  local previous = package.loaded[name]
  package.loaded[name] = nil
  local ok, fresh = pcall(require, name)
  package.loaded[name] = previous
  assert(ok, ('helpers.fresh_module: %s failed to load: %s'):format(name, tostring(fresh)))
  return fresh
end

--- Whether `needle` occurs in any string reachable from `value`. Used to prove that a secret
--- never reaches argv.
---@param value any
---@param needle string
---@return boolean
function M.leaks(value, needle)
  assert(type(needle) == 'string' and needle ~= '', 'helpers.leaks: needle must be a string')
  for _, text in ipairs(M.strings(value)) do
    if text:find(needle, 1, true) then
      return true
    end
  end
  return false
end

return M
