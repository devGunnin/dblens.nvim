--- Searching the result already in memory.
---
--- Matching runs over the UNDERLYING cell values, not the grid's rendered text: the grid clips a
--- cell at `ui.grid.max_col_width`, so a match inside a long value is invisible to the buffer's
--- own `/`. Pure: this module finds positions, the grid highlights them.
local protocol = require('dblens.protocol')

local M = {}

---@class dblens.Match
---@field row integer     -- 1-based index into result.rows
---@field column integer  -- 1-based index into result.columns

--- Every cell containing `term`, case-insensitively, in row-major order.
---
--- Plain substring, never a pattern: a user searching for `a.b` or `50%` means those characters.
---@param result dblens.ResultSet
---@param term string
---@return dblens.Match[] matches, table<string, boolean> keys  -- keys are `row .. ':' .. column`
function M.find(result, term)
  assert(type(result) == 'table' and vim.islist(result.rows), 'search.find: expected a result set')
  assert(type(term) == 'string' and term ~= '', 'search.find: needs a non-empty term')
  local needle = term:lower()
  local matches, keys = {}, {}
  for r, row in ipairs(result.rows) do
    for c = 1, #result.columns do
      local cell = row[c]
      if cell ~= nil and cell ~= protocol.NULL then
        if tostring(cell):lower():find(needle, 1, true) then
          matches[#matches + 1] = { row = r, column = c }
          keys[r .. ':' .. c] = true
        end
      end
    end
  end
  assert(#matches == vim.tbl_count(keys), 'search.find: a match must have exactly one key')
  return matches, keys
end

--- Step through matches, wrapping at either end.
---@param count integer
---@param index integer  -- 1-based
---@param delta integer
---@return integer
function M.step(count, index, delta)
  assert(count >= 1, 'search.step: nothing to step through')
  assert(index >= 1 and index <= count, 'search.step: index is outside the match list')
  return (index + delta - 1) % count + 1
end

return M
