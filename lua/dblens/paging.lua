--- Paging arithmetic for the results grid. Pure, 1-based pages.
---
--- `total` is optional: a count query is only run when it is cheap enough to want, so the grid
--- must stay usable knowing nothing but "the page we fetched came back full".
local M = {}

---@class dblens.Paging
---@field page integer   -- 1-based
---@field size integer   -- rows per page
---@field total integer? -- total rows when counted

---@param size integer
---@param total integer?
---@return dblens.Paging
function M.new(size, total)
  assert(
    type(size) == 'number' and size >= 1 and size == math.floor(size),
    'paging.new: size must be a positive integer'
  )
  assert(total == nil or total >= 0, 'paging.new: total must not be negative')
  return { page = 1, size = size, total = total }
end

---@param state dblens.Paging
---@return integer rows to skip
function M.offset(state)
  assert(state.page >= 1, 'paging.offset: page is 1-based')
  return (state.page - 1) * state.size
end

--- Number of pages, or nil when the total is unknown.
---@return integer?
function M.page_count(state)
  if not state.total then
    return nil
  end
  return math.max(1, math.ceil(state.total / state.size))
end

function M.can_prev(state)
  return state.page > 1
end

--- Without a total, a full page is the only evidence that more rows may exist.
---@param rows_on_page integer
function M.can_next(state, rows_on_page)
  assert(type(rows_on_page) == 'number' and rows_on_page >= 0, 'paging.can_next: need a row count')
  local pages = M.page_count(state)
  if pages then
    return state.page < pages
  end
  return rows_on_page >= state.size
end

--- Move by `delta` pages, refusing to leave the known range. Returns the new state and whether
--- it actually moved, so the caller can avoid a pointless refetch.
---@return dblens.Paging, boolean moved
function M.step(state, delta, rows_on_page)
  assert(
    type(delta) == 'number' and delta == math.floor(delta),
    'paging.step: delta must be an integer'
  )
  local target = state.page + delta
  local pages = M.page_count(state)
  if target < 1 then
    target = 1
  end
  if pages and target > pages then
    target = pages
  end
  if delta > 0 and not pages and not M.can_next(state, rows_on_page or 0) then
    target = state.page
  end
  local moved = target ~= state.page
  return vim.tbl_extend('force', state, { page = target }), moved
end

---@return dblens.Paging, boolean moved
function M.goto_page(state, page, rows_on_page)
  assert(type(page) == 'number' and page >= 1, 'paging.goto_page: page is 1-based')
  return M.step(state, page - state.page, rows_on_page)
end

local function group_digits(n)
  local text = tostring(math.floor(n))
  local out = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  return (out:gsub('^,', ''))
end

--- Human range for the winbar, e.g. `101-200 of 4,231` or `101-200` when uncounted.
---@param state dblens.Paging
---@param rows_on_page integer
---@return string
function M.label(state, rows_on_page)
  if rows_on_page == 0 then
    return state.total and ('0 of ' .. group_digits(state.total)) or '0 rows'
  end
  local first = M.offset(state) + 1
  local last = first + rows_on_page - 1
  local range = ('%s-%s'):format(group_digits(first), group_digits(last))
  if state.total then
    return ('%s of %s'):format(range, group_digits(state.total))
  end
  return range
end

return M
