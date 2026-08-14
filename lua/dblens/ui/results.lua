--- The results grid: draws a result set, locates the cell under the cursor, and owns paging,
--- sorting, filtering and yanking.
---
--- Highlights are applied in scheduled chunks. A wide page can carry tens of thousands of
--- extmarks, and setting them all in one tick is what makes a grid feel janky.
local export = require('dblens.export')
local grid = require('dblens.render.grid')
local keymaps = require('dblens.keymaps')
local layout_mod = require('dblens.ui.layout')
local paging = require('dblens.paging')
local protocol = require('dblens.protocol')
local status = require('dblens.ui.status')

local api = vim.api

local M = {}

local NAMESPACE = api.nvim_create_namespace('dblens.results')

--- Bumped on every render; in-flight chunk loops from an older render stop when they notice.
local generation = 0

local function apply_marks(buf, marks, chunk_size, token)
  local index = 1
  local function step()
    if token ~= generation or not api.nvim_buf_is_valid(buf) then
      return
    end
    local last = math.min(index + chunk_size - 1, #marks)
    for at = index, last do
      local mark = marks[at]
      api.nvim_buf_set_extmark(
        buf,
        NAMESPACE,
        mark.line,
        mark.col,
        { end_col = mark.end_col, hl_group = mark.hl }
      )
    end
    index = last + 1
    if index <= #marks then
      vim.schedule(step)
    end
  end
  step()
end

local function placeholder_lines(state)
  if state.grid.error then
    local lines = { '', '  query failed', '' }
    for line in tostring(state.grid.error):gmatch('[^\n]+') do
      lines[#lines + 1] = '  ' .. line
    end
    return lines, 'DbLensError'
  end
  if state.grid.message then
    return { '', '  ' .. state.grid.message }, 'DbLensDim'
  end
  if not state.session then
    return { '', '  not connected' }, 'DbLensDim'
  end
  return { '', '  select a table, or run a query above' }, 'DbLensDim'
end

--- Redraw the grid.
---@param state dblens.State
function M.render(state)
  local buf, win = state.layout.bufs.results, state.layout.wins.results
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  generation = generation + 1
  api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)

  local output = require('dblens.app').grid_output()
  state.grid.spans = output and output.spans or {}
  state.grid.header_lines = output and output.header_lines or 0

  if not output then
    local lines, hl = placeholder_lines(state)
    layout_mod.set_lines(buf, lines)
    for index = 2, #lines do
      api.nvim_buf_set_extmark(
        buf,
        NAMESPACE,
        index - 1,
        0,
        { end_col = #lines[index], hl_group = hl }
      )
    end
    M.render_winbar(state)
    return
  end

  layout_mod.set_lines(buf, output.lines)
  apply_marks(buf, output.marks, state.options.ui.grid.chunk_size, generation)
  if api.nvim_win_is_valid(win) then
    -- Keep the cursor on a data row after a redraw shortens the page.
    local cursor = api.nvim_win_get_cursor(win)
    local max = math.max(1, #output.lines)
    if cursor[1] > max then
      api.nvim_win_set_cursor(win, { max, 0 })
    end
  end
  M.render_winbar(state)
end

--- The winbar alone. The spinner ticks through here, so it must stay cheap.
---@param state dblens.State
function M.render_winbar(state)
  local win = state.layout and state.layout.wins.results
  if not win or not api.nvim_win_is_valid(win) then
    return
  end
  local session, source = state.session, state.grid.source
  local segments = {
    { text = ' ' .. (source and source.label or 'results'), hl = 'DbLensTitle' },
  }
  if state.grid.result then
    -- Only a browsed relation is paged; a query result is just however many rows came back.
    local rows = #state.grid.result.rows
    local text = source and source.kind == 'relation' and paging.label(state.grid.paging, rows)
      or ('%d row%s'):format(rows, rows == 1 and '' or 's')
    segments[#segments + 1] = { text = text, hl = 'DbLensDim' }
  end
  if state.grid.sort then
    segments[#segments + 1] = {
      text = ('sort %s %s'):format(
        state.grid.sort.column,
        state.grid.sort.desc and 'desc' or 'asc'
      ),
      hl = 'DbLensSortKey',
    }
  end
  if state.grid.filter then
    segments[#segments + 1] = { text = 'where ' .. state.grid.filter, hl = 'DbLensAccent' }
  end
  if state.grid.elapsed_ms then
    segments[#segments + 1] = { text = status.duration(state.grid.elapsed_ms), hl = 'DbLensDim' }
  end
  if state.grid.truncated then
    segments[#segments + 1] = { text = 'truncated', hl = 'DbLensWarn' }
  end
  if session and session.txn:is_active() then
    segments[#segments + 1] = { text = session.txn:label(), hl = 'DbLensTxn' }
  end
  if session and session:is_read_only() then
    segments[#segments + 1] = { text = 'read-only', hl = 'DbLensReadOnly' }
  end
  if state.spinner and state.spinner:is_running() then
    segments[#segments + 1] = { text = state.spinner:label(), hl = 'DbLensSpinner' }
  end
  status.set(win, segments)
end

---@class dblens.Cell
---@field row integer      -- 1-based index into result.rows
---@field column integer   -- 1-based index into result.columns
---@field name string
---@field value any

--- The cell under the cursor, or nil with a reason.
---@return dblens.Cell?, string?
function M.current_cell(state)
  local result = state.grid.result
  local win = state.layout.wins.results
  if not result or #result.columns == 0 or not api.nvim_win_is_valid(win) then
    return nil, 'no result is shown'
  end
  local cursor = api.nvim_win_get_cursor(win)
  local row = cursor[1] - state.grid.header_lines
  if row < 1 or row > #result.rows then
    return nil, 'put the cursor on a data row'
  end
  local column = grid.nearest_column(state.grid.spans, vim.fn.virtcol({ cursor[1], cursor[2] }))
  if not column then
    return nil, 'put the cursor on a column'
  end
  return {
    row = row,
    column = column,
    name = result.columns[column],
    value = result.rows[row][column],
  },
    nil
end

--- Run `fn` with the current cell, reporting why not when there is none.
local function with_cell(state, app, fn)
  return function()
    local cell, err = M.current_cell(state)
    if not cell then
      app.notify(err)
      return
    end
    fn(cell)
  end
end

local function yank(app, text, what)
  vim.fn.setreg(vim.v.register or '"', text)
  app.notify(('yanked %s'):format(what))
end

local function handlers(state, app)
  local crud = require('dblens.ui.crud')
  local function row_result(cell)
    return {
      columns = state.grid.result.columns,
      rows = { state.grid.result.rows[cell.row] },
      malformed = 0,
    }
  end

  return {
    detail = with_cell(state, app, function(cell)
      require('dblens.ui.detail').row(state, cell.row)
    end),
    next_page = function()
      app.page(1)
    end,
    prev_page = function()
      app.page(-1)
    end,
    sort = with_cell(state, app, function(cell)
      app.sort_by(cell.name)
    end),
    filter = function()
      vim.ui.input({ prompt = 'WHERE ', default = state.grid.filter or '' }, function(input)
        if input ~= nil then
          app.set_filter(input)
        end
      end)
    end,
    refresh = function()
      app.refresh_grid()
    end,
    edit_cell = with_cell(state, app, function(cell)
      crud.edit_cell(state, cell)
    end),
    insert_row = function()
      crud.insert_row(state)
    end,
    delete_row = with_cell(state, app, function(cell)
      crud.delete_row(state, cell.row)
    end),
    yank_cell = with_cell(state, app, function(cell)
      yank(app, protocol.tostring(cell.value), 'cell')
    end),
    yank_row = with_cell(state, app, function(cell)
      yank(app, export.to_csv(row_result(cell), { header = false }), 'row as CSV')
    end),
    yank_json = with_cell(state, app, function(cell)
      yank(app, export.to_json(row_result(cell)), 'row as JSON')
    end),
    yank_insert = with_cell(state, app, function(cell)
      local source = state.grid.source
      if not source or source.kind ~= 'relation' then
        app.notify('an INSERT needs a table, not a query result')
        return
      end
      local mutate = require('dblens.mutate')
      yank(
        app,
        mutate.insert_text(
          source.relation,
          state.grid.result.columns,
          state.grid.result.rows[cell.row],
          state.session.adapter.dialect
        ),
        'row as INSERT'
      )
    end),
    export = function()
      crud.export(state)
    end,
    help = function()
      require('dblens.ui.help').show(state, 'results')
    end,
    close = function()
      app.close()
    end,
  }
end

---@param state dblens.State
function M.attach(state)
  local app = require('dblens.app')
  keymaps.bind(
    'results',
    state.layout.bufs.results,
    handlers(state, app),
    state.options.keymaps.results
  )
end

return M
