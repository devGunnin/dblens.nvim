--- The results grid: draws a result set, locates the cell under the cursor, and owns paging,
--- sorting, filtering and yanking.
---
--- Highlights are applied in scheduled chunks. A wide page can carry tens of thousands of
--- extmarks, and setting them all in one tick is what makes a grid feel janky.
local empty = require('dblens.ui.empty')
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

--- `config.validate` refuses a chunk size below 1; the clamp is the second lock on the same door,
--- because a loop that reschedules without advancing takes the whole editor down with it — 100%
--- CPU, `:q` unreachable, SIGTERM ignored, SIGKILL the only way out.
local function apply_marks(buf, marks, chunk_size, token)
  local chunk = math.max(1, math.floor(tonumber(chunk_size) or 1))
  local index = 1
  local function step()
    if token ~= generation or not api.nvim_buf_is_valid(buf) then
      return
    end
    local last = math.min(index + chunk - 1, #marks)
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
    assert(last >= index or index > #marks, 'results.apply_marks: a chunk must make progress')
    index = last + 1
    if index <= #marks then
      vim.schedule(step)
    end
  end
  step()
end

--- The failed query, its message readable rather than a wall of red.
local function error_panel(state, icons)
  local detail = {}
  for line in tostring(state.grid.error):gmatch('[^\n]+') do
    detail[#detail + 1] = { text = line, hl = 'DbLensNormal' }
  end
  return empty.panel(icons.error .. '  query failed', detail, 'DbLensError')
end

--- What the grid shows in place of rows, and the marks that colour it.
---@return string[] lines, dblens.Mark[] marks
local function placeholder(state, icons)
  local options = state.options
  if state.grid.error then
    return error_panel(state, icons)
  end
  if state.grid.message then
    return empty.panel(icons.table .. '  ' .. state.grid.message, {})
  end
  if not state.session then
    return empty.panel(icons.database .. '  not connected', {
      { key = keymaps.lhs_for('global', 'connections', options.keymaps.global), text = 'connect' },
    })
  end
  return empty.panel(icons.table .. '  no result yet', {
    {
      key = keymaps.lhs_for('sidebar', 'select', options.keymaps.sidebar),
      text = 'in the tree: open a table',
    },
    {
      key = keymaps.lhs_for('editor', 'run', options.keymaps.editor),
      text = 'in the editor: run a statement',
    },
    { key = keymaps.lhs_for('results', 'help', options.keymaps.results), text = 'every binding' },
  })
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

  local icons = state.icons
  local output = require('dblens.app').grid_output()
  state.grid.spans = output and output.spans or {}
  state.grid.header_lines = output and output.header_lines or 0

  if not output then
    local lines, marks = placeholder(state, icons)
    layout_mod.set_lines(buf, lines)
    for _, mark in ipairs(marks) do
      api.nvim_buf_set_extmark(
        buf,
        NAMESPACE,
        mark.line,
        mark.col,
        { end_col = mark.end_col, hl_group = mark.hl }
      )
    end
    M.render_winbar(state)
    return
  end

  -- A table with no matching rows keeps its header, and says so rather than ending in blank space.
  if #state.grid.result.rows == 0 then
    local at = #output.lines
    output.lines[at + 1] = '  no rows'
    output.marks[#output.marks + 1] =
      { line = at, col = 0, end_col = #output.lines[at + 1], hl = 'DbLensDim' }
  end

  layout_mod.set_lines(buf, output.lines)
  apply_marks(buf, output.marks, state.options.ui.grid.chunk_size, generation)
  if api.nvim_win_is_valid(win) then
    -- Keep the cursor on a data row: on the header nothing the grid binds works, and a redraw
    -- that shortens the page can leave it past the end.
    local cursor = api.nvim_win_get_cursor(win)
    local max = math.max(1, #output.lines)
    local first_row = output.header_lines + 1
    if cursor[1] > max then
      api.nvim_win_set_cursor(win, { max, 0 })
    elseif cursor[1] < first_row and #state.grid.result.rows > 0 then
      api.nvim_win_set_cursor(win, { first_row, cursor[2] })
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
    { text = ' ' .. (source and source.label or 'results'), hl = 'DbLensTitle', keep = true },
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
  -- Where the view came from, when it was navigated to rather than opened: without it a table
  -- that appeared because a foreign key was followed looks like one the user opened themselves.
  if source and source.origin then
    segments[#segments + 1] = { text = '<- ' .. source.origin, hl = 'DbLensFK' }
  end
  if state.grid.filter then
    segments[#segments + 1] = { text = 'where ' .. state.grid.filter, hl = 'DbLensAccent' }
  end
  if state.grid.search then
    segments[#segments + 1] = {
      text = ('/%s %d/%d'):format(
        state.grid.search.term,
        state.grid.search.index,
        #state.grid.search.matches
      ),
      hl = 'DbLensMatch',
    }
  end
  if state.grid.elapsed_ms then
    segments[#segments + 1] = { text = status.duration(state.grid.elapsed_ms), hl = 'DbLensDim' }
  end
  if state.grid.truncated then
    -- Kept: the rows on screen are not all of them, and a narrow window must still say so.
    segments[#segments + 1] = { text = 'truncated', hl = 'DbLensWarn', keep = true }
  end
  if session and session.txn:is_active() then
    segments[#segments + 1] = { text = session.txn:label(), hl = 'DbLensTxn', keep = true }
  end
  if session then
    local icons = state.icons
    segments[#segments + 1] = session:is_read_only()
        and { text = icons.lock .. ' LOCKED', hl = 'DbLensLocked', keep = true }
      or { text = icons.edit .. ' EDIT', hl = 'DbLensEdit', keep = true }
  end
  if state.spinner and state.spinner:is_running() then
    segments[#segments + 1] = { text = state.spinner:label(), hl = 'DbLensSpinner', keep = true }
  end
  status.set(win, segments, state.options)
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

--- Put the cursor on a match, so a hit inside a clipped cell can still be read (`<CR>` opens the
--- row detail, which shows the value in full).
---@param match dblens.Match?
function M.focus_match(state, match)
  local win = state.layout.wins.results
  if not match or not api.nvim_win_is_valid(win) then
    return
  end
  local line = match.row + state.grid.header_lines
  local span = state.grid.spans[match.column]
  if line > api.nvim_buf_line_count(state.layout.bufs.results) or not span then
    return
  end
  -- Spans are DISPLAY columns; the cursor takes a byte column, and a multibyte cell above makes
  -- those differ.
  local byte = vim.fn.virtcol2col(win, line, span.from)
  api.nvim_win_set_cursor(win, { line, math.max(0, byte - 1) })
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
    first_page = function()
      app.page_edge('first')
    end,
    last_page = function()
      app.page_edge('last')
    end,
    goto_page = function()
      vim.ui.input({ prompt = 'Go to page ' }, function(input)
        if input == nil or vim.trim(input) == '' then
          return
        end
        local page = tonumber(vim.trim(input))
        if not page or page ~= math.floor(page) then
          app.notify(('`%s` is not a page number'):format(vim.trim(input)))
          return
        end
        app.goto_page(page)
      end)
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
    filter_cell = with_cell(state, app, function(cell)
      app.filter_by_cell(cell, '=')
    end),
    filter_not_cell = with_cell(state, app, function(cell)
      app.filter_by_cell(cell, '<>')
    end),
    clear_filter = function()
      app.clear_filter()
    end,
    refresh = function()
      app.refresh_grid()
    end,
    follow_fk = with_cell(state, app, function(cell)
      app.follow_fk(cell)
    end),
    search = function()
      vim.ui.input({
        prompt = 'Search ',
        default = state.grid.search and state.grid.search.term or '',
      }, function(input)
        if input == nil then
          return
        end
        M.focus_match(state, app.search_result(input))
      end)
    end,
    next_match = function()
      M.focus_match(state, app.step_match(1))
    end,
    prev_match = function()
      M.focus_match(state, app.step_match(-1))
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
      require('dblens.ui.exporter').prompt_current(state)
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
