--- The connections manager: every connection dblens knows about, whether it can be opened right
--- now, and the actions that fix it.
---
--- Health is computed WITHOUT connecting: a reference is resolved, a database is not opened. That
--- is the whole point — the connection this exists for is the one that cannot connect, and finding
--- that out must not cost a timeout, a password prompt, or an error on every start.
local adapters = require('dblens.adapters')
local connections = require('dblens.connections')
local float = require('dblens.ui.float')
local keymaps = require('dblens.keymaps')

local api = vim.api

local M = {}

local NAMESPACE = api.nvim_create_namespace('dblens.manager')

---@class dblens.ManagerRow
---@field name string?  -- nil unless the entry has a usable name; nothing may be keyed on it
---@field label string  -- what to call this row on screen, broken entries included
---@field source 'config'|'file'|'discovered'
---@field index integer?  -- position in the connections file; nil unless `source` is 'file'
---@field health dblens.ConnectionHealth
---@field cells string[]

local HEADING = { 'connection', 'engine', 'target', 'mode', 'password' }

--- One cell wide in every icon set, so the columns line up whichever one is configured.
---@param icons table
---@return table<string, string>
local function flags(icons)
  return { ok = ' ', broken = icons and icons.error or '!', unknown = '?' }
end

--- Where a connection's password comes from, never which value or which variable's value.
local function secret_label(spec)
  -- dblens never writes one, so saying "none" over a hand-written plaintext password would hide
  -- the one thing about this entry worth saying.
  if connections.plaintext_password_key(spec) then
    return 'plaintext!'
  end
  if type(spec.password_env) == 'string' then
    return '$' .. spec.password_env
  end
  if spec.password_env ~= nil then
    return '$?'
  end
  if spec.password_cmd ~= nil then
    return 'command'
  end
  if spec.source == 'discovered' then
    return 'session'
  end
  return 'none'
end

--- Whether every adapter field this spec fills is a scalar. A JSON object where a host belongs
--- describes without raising and renders a Lua table address, which tells the user nothing.
local function scalar_fields(spec, adapter)
  for _, field in ipairs(adapter.fields or {}) do
    local value = spec[field.name]
    local kind = type(value)
    if value ~= nil and kind ~= 'string' and kind ~= 'number' and kind ~= 'boolean' then
      return false
    end
  end
  return true
end

local function target_label(spec)
  local adapter = adapters.get(spec.kind)
  if not adapter or not scalar_fields(spec, adapter) then
    return '?'
  end
  local ok, described = pcall(adapter.describe, spec)
  if not ok or type(described) ~= 'string' then
    return '?'
  end
  return described
end

--- The stored `name`, but only when it is one that can be used as a name.
local function usable_name(value)
  if type(value) == 'string' and value ~= '' then
    return value
  end
  return nil
end

--- What to call an entry on screen. A name that cannot be used is still SHOWN, because the user
--- has to be able to find the entry in the file.
local function name_label(value)
  local usable = usable_name(value)
  if usable then
    return usable
  end
  if value == nil then
    return '(no name)'
  end
  if type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean' then
    return ('(invalid name: %s)'):format(tostring(value))
  end
  return '(invalid name)'
end

--- One row, built from an entry that may be anything the file happened to hold.
---@param spec dblens.ConnectionSpec  -- every field access here is guarded
---@param source 'config'|'file'|'discovered'
---@param health dblens.ConnectionHealth
---@param index integer?  -- position in the connections file
---@return dblens.ManagerRow
local function row_for(spec, source, health, index)
  assert(type(spec) == 'table', 'manager.row_for: expected a spec table')
  local kind = type(spec.kind) == 'string' and spec.kind or '?'
  local mode = spec.read_only == false and 'EDIT' or 'LOCKED'
  local label = name_label(spec.name)
  local cells = { label, kind, target_label(spec), mode, secret_label(spec) }
  if source ~= 'file' then
    cells[1] = cells[1] .. ' (' .. source .. ')'
  end
  return {
    name = usable_name(spec.name),
    label = label,
    source = source,
    index = index,
    health = health,
    cells = cells,
  }
end

--- Why the manager cannot change this row, or nil when it can.
---
--- Only a stored row is changeable, and only through the position it occupies in the file.
---@param row dblens.ManagerRow
---@return string? problem
function M.editable_problem(row)
  assert(type(row) == 'table' and row.label, 'manager.editable_problem: expected a row')
  if row.source == 'file' and row.index then
    return nil
  end
  if row.source == 'config' then
    return ('`%s` comes from setup{} - change it there'):format(row.label)
  end
  return ('`%s` was discovered for this session - `a` saves one like it'):format(row.label)
end

--- Every connection to show: the configured and stored ones, then the discovered ones this
--- session found. A discovered connection is marked and never written to disk.
---@param state dblens.State
---@return dblens.ManagerRow[] rows, string? file_error
function M.rows(state)
  assert(type(state) == 'table' and state.options, 'manager.rows: expected the app state')
  local entries, file_error = connections.entries(state.options)
  local rows, seen = {}, {}
  for _, entry in ipairs(entries) do
    local named = usable_name(entry.spec.name)
    if named then
      seen[named] = true
    end
    rows[#rows + 1] =
      row_for(entry.spec, entry.source, connections.health(entry.spec, entry.problem), entry.index)
  end
  for _, spec in ipairs(state.specs or {}) do
    if spec.source == 'discovered' and not seen[spec.name] then
      rows[#rows + 1] = row_for(spec, 'discovered', { state = 'ok' })
    end
  end
  return rows, file_error
end

--- Lay the rows out in aligned columns, each one preceded by its health flag.
---@param rows dblens.ManagerRow[]
---@param file_error string?
---@param icons table?
---@return string[] lines, table<integer, integer> row_at  -- 0-based line -> index into `rows`
function M.render(rows, file_error, icons)
  local flag_for = flags(icons)
  local widths = {}
  for index, heading in ipairs(HEADING) do
    widths[index] = #heading
  end
  for _, row in ipairs(rows) do
    for index, cell in ipairs(row.cells) do
      widths[index] = math.max(widths[index] or 0, vim.fn.strdisplaywidth(cell))
    end
  end

  local function line(flag, cells)
    local parts = { flag }
    for index = 1, #HEADING do
      local cell = cells[index] or ''
      parts[#parts + 1] = cell .. string.rep(' ', widths[index] - vim.fn.strdisplaywidth(cell))
    end
    return (table.concat(parts, ' '):gsub('%s+$', ''))
  end

  -- The reason gets its own indented line: appended to the row it made every flagged row wider
  -- than the float, so the one thing the user opened this for was the part cut off.
  local lines, row_at = { line(' ', HEADING) }, {}
  for index, row in ipairs(rows) do
    row_at[#lines] = index
    lines[#lines + 1] = line(flag_for[row.health.state], row.cells)
    if row.health.state ~= 'ok' and row.health.reason then
      row_at[#lines] = index
      lines[#lines + 1] = '    ' .. row.health.reason
    end
  end
  if #rows == 0 then
    lines[#lines + 1] = '  no connections yet - `a` adds one, `D` looks through this project'
  end
  if file_error then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '! ' .. file_error
  end
  return lines, row_at
end

--- The row the cursor is on, or nil when it is on the heading or a filler line.
local function row_under_cursor(popup, rows, row_at)
  if not api.nvim_win_is_valid(popup.win) then
    return nil
  end
  return rows[row_at[api.nvim_win_get_cursor(popup.win)[1] - 1]]
end

local function highlight(popup, rows, row_at)
  api.nvim_buf_clear_namespace(popup.buf, NAMESPACE, 0, -1)
  api.nvim_buf_set_extmark(popup.buf, NAMESPACE, 0, 0, { end_row = 1, hl_group = 'DbLensDim' })
  for line, index in pairs(row_at) do
    local state = rows[index].health.state
    local group = state == 'broken' and 'DbLensError' or (state == 'unknown' and 'DbLensDim' or nil)
    if group then
      pcall(api.nvim_buf_set_extmark, popup.buf, NAMESPACE, line, 0, {
        end_row = line + 1,
        hl_group = group,
        hl_eol = true,
      })
    end
  end
end

--- Close the manager, run something that asks its own questions, and come back to a fresh list.
---
--- Closed FIRST: `vim.ui.input` and the confirmation are windows of their own, and leaving this
--- float open under them would have it close itself the moment focus moved.
local function step_out(popup, state, action)
  popup.close()
  vim.schedule(function()
    action(function()
      M.open(state)
    end)
  end)
end

local function confirm_delete(state, row, on_done)
  local reason = (row.health.state ~= 'ok' and row.health.reason) and { row.health.reason } or {}
  require('dblens.ui.confirm').ask(state.options, {
    title = ('Delete connection `%s`?'):format(row.label),
    danger = true,
    sections = {
      { heading = 'connection', lines = { row.cells[1] .. '  ' .. row.cells[3] } },
      { heading = 'why it is flagged', lines = reason, hl = 'DbLensError' },
      {
        heading = 'what happens',
        lines = {
          'removed from the connections file',
          'the saved session stops pointing at it',
        },
      },
    },
  }, function()
    require('dblens.ui.form').remove(state.options, row.index, on_done)
  end)
end

--- Open the connection a row names.
---
--- Connecting is BY NAME, so a row without a usable one has nothing to connect to and says so.
local function connect_row(popup, row)
  if not row.name then
    require('dblens.app').notify(
      ('`%s` has no usable name - fix it with `e`, or delete it with `dd`'):format(row.label)
    )
    return
  end
  popup.close()
  vim.schedule(function()
    require('dblens.app').connect(row.name)
  end)
end

--- Whether `e` and `dd` may act on this row, saying why not when they may not. A BROKEN entry
--- passes: fixing or deleting it is the point.
local function changeable(row)
  local problem = M.editable_problem(row)
  if problem then
    require('dblens.app').notify(problem)
    return false
  end
  return true
end

local function handlers(popup, state, rows, row_at)
  local function current()
    local row = row_under_cursor(popup, rows, row_at)
    if not row then
      require('dblens.app').notify('put the cursor on a connection first')
    end
    return row
  end

  return {
    connect = function()
      local row = current()
      if row then
        connect_row(popup, row)
      end
    end,
    edit = function()
      local row = current()
      if row and changeable(row) then
        step_out(popup, state, function(done)
          require('dblens.ui.form').edit(state.options, row.index, done)
        end)
      end
    end,
    delete = function()
      local row = current()
      if row and changeable(row) then
        step_out(popup, state, function(done)
          confirm_delete(state, row, done)
        end)
      end
    end,
    add = function()
      step_out(popup, state, function(done)
        require('dblens.ui.form').add(state.options, done)
      end)
    end,
    discover = function()
      popup.close()
      vim.schedule(function()
        require('dblens.app').discover()
      end)
    end,
    refresh = function()
      popup.close()
      vim.schedule(function()
        M.open(state)
      end)
    end,
    help = function()
      require('dblens.ui.help').show(state, 'connections')
    end,
    close = function()
      popup.close()
    end,
  }
end

--- Open the manager.
---@param state dblens.State
---@return dblens.Float
function M.open(state)
  assert(type(state) == 'table' and state.options, 'manager.open: expected the app state')
  local rows, file_error = M.rows(state)
  local lines, row_at = M.render(rows, file_error, state.icons)

  local popup = float.open(lines, state.options, {
    title = 'Connections',
    footer = '<CR> connect · e edit · dd delete · a add · ? help · q close',
    min_width = 60,
    cursorline = true,
    close_keys = { '<Esc>' },
  })
  highlight(popup, rows, row_at)
  if #rows > 0 and api.nvim_win_is_valid(popup.win) then
    api.nvim_win_set_cursor(popup.win, { 2, 0 })
  end
  keymaps.bind(
    'connections',
    popup.buf,
    handlers(popup, state, rows, row_at),
    state.options.keymaps.connections
  )
  return popup
end

return M
