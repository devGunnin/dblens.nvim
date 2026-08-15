--- Result tabs: several result sets open at once, one of them on screen.
---
--- A tab IS a grid state — its result, where the rows came from, its paging, sort, filter and
--- search — and its OWN `epoch` and `fetch` guards. Per tab, deliberately: a slow query started
--- in one tab must never write its rows into another, and a single shared counter cannot tell
--- those two requests apart. Every async caller captures the grid it dispatched for and checks
--- that grid's token when the rows arrive.
---
--- Pure data: nothing here draws anything, runs anything, or knows what a session is.
local paging = require('dblens.paging')

local M = {}

--- An empty grid state — what a fresh tab shows before anything has run in it.
---@param options table  resolved config
---@return table
function M.new_grid(options)
  assert(type(options) == 'table' and options.page_size, 'tabs.new_grid: needs resolved options')
  return {
    source = nil,
    result = nil,
    paging = paging.new(options.page_size),
    sort = nil,
    filter = nil,
    spans = {},
    types = nil,
    dirty = {},
    --- In-result search: the term, its matches, and which one is current. Indexes into the
    --- CURRENT rows, so it is dropped whenever a new result is presented.
    search = nil,
    message = nil,
    error = nil,
    truncated = false,
    elapsed_ms = nil,
    --- Identity of what this TAB is showing, and of its current fetch. A result carrying a token
    --- this grid has moved past belongs to a superseded request and is dropped.
    epoch = 0,
    fetch = 0,
    --- The client call this tab started. Held per tab so opening or switching tabs never cancels
    --- another tab's query.
    job = nil,
  }
end

---@class dblens.TabSet
---@field list table[]      -- grid states, in tab order
---@field active integer    -- 1-based index into `list`

--- A tab set with one empty tab, which is what a fresh UI opens with.
---@param options table
---@return dblens.TabSet
function M.new(options)
  return { list = { M.new_grid(options) }, active = 1 }
end

--- The two invariants every caller depends on: there is always a tab, and `active` names one.
---@param set dblens.TabSet
---@return dblens.TabSet
local function checked(set)
  assert(type(set) == 'table' and vim.islist(set.list), 'tabs: expected a tab set')
  assert(#set.list > 0, 'tabs: a tab set always holds at least one tab')
  assert(
    type(set.active) == 'number' and set.active >= 1 and set.active <= #set.list,
    'tabs: the active tab is out of range'
  )
  return set
end

---@param set dblens.TabSet
---@return table grid
function M.active(set)
  return checked(set).list[set.active]
end

---@param set dblens.TabSet
---@return integer
function M.count(set)
  return #checked(set).list
end

--- Add a tab beside the active one and make it current.
---
--- Capped: each tab holds a whole result set, so an unbounded number of them is unbounded memory.
---@param set dblens.TabSet
---@param options table
---@param max integer
---@return integer? index, string? error
function M.open(set, options, max)
  checked(set)
  assert(type(max) == 'number' and max >= 1, 'tabs.open: needs a positive cap')
  if #set.list >= max then
    return nil,
      ('%d result tabs is the limit (`ui.results.max_tabs`) - close one first'):format(max)
  end
  table.insert(set.list, set.active + 1, M.new_grid(options))
  set.active = set.active + 1
  return set.active, nil
end

--- Retire the active tab.
---
--- The last tab is emptied rather than removed: the grid always has a tab to draw, so closing the
--- only result leaves the same empty pane a fresh session opens with.
---@param set dblens.TabSet
---@param options table
---@return boolean removed  -- false when the last tab was emptied instead
function M.close(set, options)
  checked(set)
  if #set.list == 1 then
    set.list[1] = M.new_grid(options)
    return false
  end
  table.remove(set.list, set.active)
  set.active = math.min(set.active, #set.list)
  return true
end

--- Move `delta` tabs along, wrapping.
---@param set dblens.TabSet
---@param delta integer
---@return integer index
function M.step(set, delta)
  checked(set)
  assert(type(delta) == 'number' and delta ~= 0, 'tabs.step: needs a non-zero delta')
  set.active = (set.active + delta - 1) % #set.list + 1
  return set.active
end

--- Show the tab at `index`, or report that there is no such tab.
---@param set dblens.TabSet
---@param index integer
---@return boolean ok
function M.select(set, index)
  checked(set)
  if type(index) ~= 'number' or index < 1 or index > #set.list or index ~= math.floor(index) then
    return false
  end
  set.active = index
  return true
end

--- Which tab holds `grid`, or nil when it is not in this set.
---@param set dblens.TabSet
---@param grid table
---@return integer?
function M.index_of(set, grid)
  for index, entry in ipairs(checked(set).list) do
    if entry == grid then
      return index
    end
  end
  return nil
end

--- What a tab is showing, short enough for the indicator.
---@param grid table
---@return string
function M.label(grid)
  assert(type(grid) == 'table', 'tabs.label: expected a grid state')
  local source = grid.source
  if not source then
    return 'empty'
  end
  if source.label and source.label ~= '' then
    return source.label
  end
  return source.kind == 'relation' and source.relation.name or 'result'
end

--- One line per tab for the tab list, so the picker and the indicator agree on the wording.
---@param set dblens.TabSet
---@return { index: integer, label: string, detail: string, active: boolean }[]
function M.describe(set)
  local out = {}
  for index, grid in ipairs(checked(set).list) do
    local rows = grid.result and #grid.result.rows or nil
    local parts = {}
    if grid.source then
      parts[#parts + 1] = grid.source.kind == 'relation' and 'table' or 'query'
    end
    if rows then
      parts[#parts + 1] = ('%d row%s'):format(rows, rows == 1 and '' or 's')
    end
    if grid.filter then
      parts[#parts + 1] = 'filtered'
    end
    if grid.error then
      parts[#parts + 1] = 'failed'
    end
    out[#out + 1] = {
      index = index,
      label = M.label(grid),
      detail = table.concat(parts, '  '),
      active = index == set.active,
    }
  end
  return out
end

return M
