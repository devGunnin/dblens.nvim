--- The editing flows: cell edit, row insert, row delete, ad-hoc write confirmation, and export.
---
--- Each flow builds a statement, shows it, and only then asks the session to apply it. The
--- session enforces the rules; this module's job is to make what will happen legible first.
local confirm = require('dblens.ui.confirm')
local export = require('dblens.export')
local float = require('dblens.ui.float')
local mutate = require('dblens.mutate')
local protocol = require('dblens.protocol')
local sqlmod = require('dblens.sql')

local api = vim.api

local M = {}

local function app()
  return require('dblens.app')
end

--- The relation currently shown, or nil when the grid holds a query result.
local function current_relation(state)
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    return nil
  end
  return source.relation
end

local function guard_editable(state)
  if not state.session then
    return 'not connected'
  end
  if state.session:is_read_only() then
    return ('connection `%s` is read-only'):format(state.session.spec.name)
  end
  if not current_relation(state) then
    return 'editing needs a table; open one from the sidebar'
  end
  return nil
end

--- Apply a built change through the session, then reflect the outcome in the grid.
---@param change dblens.Change
---@param cell dblens.Cell?  -- present for a cell edit, so a queued change can be shown in place
local function apply(state, change, cell)
  state.session:execute_write({
    sql = change.sql,
    guard = change.guard,
    summary = change.summary,
    destructive = change.kind ~= 'insert',
    confirmed = true,
    change = {
      sql = change.sql,
      summary = change.summary,
      relation = change.relation,
      column = cell and cell.name or nil,
    },
  }, function(outcome, err)
    if err then
      app().error(err)
      return
    end
    if outcome.queued then
      if cell then
        -- Show the queued value in place, marked, rather than pretending it landed.
        state.grid.result.rows[cell.row][cell.column] = cell.pending
        state.grid.dirty[cell.row .. ':' .. cell.column] = true
      end
      app().notify(
        ('queued - %d change(s) pending, commit with <leader>dC'):format(state.session.txn:count())
      )
      app().render()
      return
    end
    app().notify(
      ('applied (%s row%s)'):format(
        outcome.affected or 1,
        (outcome.affected or 1) == 1 and '' or 's'
      )
    )
    app().refresh_grid()
  end)
end

--- Preview a change, then apply it if confirmed.
local function preview_and_apply(state, change, sections, cell)
  confirm.ask(state.options, {
    title = change.kind:upper() .. ' - confirm',
    danger = change.kind == 'delete',
    sections = sections,
  }, function()
    apply(state, change, cell)
  end)
end

local function key_section(state, relation, key)
  local primary = mutate.key_is_primary(state.session.catalog, relation, key)
  local parts = {}
  for _, entry in ipairs(key) do
    parts[#parts + 1] = ('%s = %s'):format(entry.column, protocol.tostring(entry.value))
  end
  return {
    heading = primary and 'identified by primary key'
      or 'identified by every column (no primary key)',
    lines = parts,
    hl = primary and 'DbLensDim' or 'DbLensWarn',
  }
end

--- Edit one cell.
---@param cell dblens.Cell
function M.edit_cell(state, cell)
  local problem = guard_editable(state)
  if problem then
    app().error(problem)
    return
  end
  local relation = current_relation(state)
  local result = state.grid.result
  local key, key_err =
    mutate.row_key(state.session.catalog, relation, result.columns, result.rows[cell.row])
  if not key then
    app().error(key_err)
    return
  end

  vim.ui.input(
    { prompt = ('%s = '):format(cell.name), default = protocol.tostring(cell.value) },
    function(input)
      if input == nil then
        return
      end
      local value = input == state.options.ui.grid.null_display and protocol.NULL or input
      local change = mutate.update(relation, key, cell.name, value, state.session.adapter.dialect)
      preview_and_apply(state, change, {
        { heading = 'statement', lines = confirm.sql_lines(change.sql), hl = 'DbLensAccent' },
        key_section(state, relation, key),
        {
          heading = 'guard',
          lines = { 'applied only if this predicate matches exactly 1 row' },
          hl = 'DbLensDim',
        },
      }, vim.tbl_extend('force', cell, { pending = value }))
    end
  )
end

--- Delete one row.
---@param row integer
function M.delete_row(state, row)
  local problem = guard_editable(state)
  if problem then
    app().error(problem)
    return
  end
  local relation = current_relation(state)
  local result = state.grid.result
  local key, key_err =
    mutate.row_key(state.session.catalog, relation, result.columns, result.rows[row])
  if not key then
    app().error(key_err)
    return
  end
  local change = mutate.delete(relation, key, state.session.adapter.dialect)
  preview_and_apply(state, change, {
    { heading = 'statement', lines = confirm.sql_lines(change.sql), hl = 'DbLensError' },
    key_section(state, relation, key),
    {
      heading = 'row',
      lines = export.row_lines(result.columns, result.rows[row]),
      hl = 'DbLensDim',
    },
  })
end

--- Open an editable statement in a float, submitting on `<CR>` or `<C-s>`.
local function statement_editor(state, title, text, on_submit)
  local lines = vim.split(text, '\n', { plain = true })
  local popup = float.open(lines, state.options, {
    title = title,
    footer = '<CR> continue · q cancel',
    modifiable = true,
    filetype = 'sql',
    min_width = 60,
  })
  local function submit()
    local edited = table.concat(api.nvim_buf_get_lines(popup.buf, 0, -1, false), '\n')
    popup.close()
    on_submit(edited)
  end
  vim.keymap.set(
    'n',
    '<CR>',
    submit,
    { buffer = popup.buf, nowait = true, desc = 'dblens: continue' }
  )
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = popup.buf, desc = 'dblens: continue' })
end

--- Insert a row by editing the generated INSERT statement.
function M.insert_row(state)
  local problem = guard_editable(state)
  if problem then
    app().error(problem)
    return
  end
  local relation = current_relation(state)
  local dialect = state.session.adapter.dialect
  local columns = state.session.catalog:info_for(relation).columns or {}
  if #columns == 0 then
    app().error('columns are not loaded for this table')
    return
  end

  local names, placeholders = {}, {}
  for _, column in ipairs(columns) do
    names[#names + 1] = sqlmod.quote_ident(column.name, dialect)
    placeholders[#placeholders + 1] = column.default or 'NULL'
  end
  local template = ('INSERT INTO %s (%s)\nVALUES (%s);'):format(
    require('dblens.adapters.common').qualify(relation, dialect),
    table.concat(names, ', '),
    table.concat(placeholders, ', ')
  )

  statement_editor(state, 'INSERT - edit the values', template, function(edited)
    local statements = sqlmod.split(edited, dialect)
    if #statements ~= 1 then
      app().error('please provide exactly one INSERT statement')
      return
    end
    local info = sqlmod.classify(statements[1].sql, dialect)
    if info.verb ~= 'INSERT' then
      app().error(('expected an INSERT, got %s'):format(info.verb ~= '' and info.verb or 'nothing'))
      return
    end
    local change = {
      kind = 'insert',
      relation = relation,
      sql = vim.trim(statements[1].sql),
      summary = ('insert 1 row into %s'):format(relation.name),
    }
    preview_and_apply(state, change, {
      { heading = 'statement', lines = confirm.sql_lines(change.sql), hl = 'DbLensAccent' },
    })
  end)
end

--- Confirm ad-hoc writes typed in the query editor.
---@param statements string[]
---@param writes dblens.Statement[]
---@param on_confirm fun()
function M.confirm_script(state, statements, writes, on_confirm)
  local session = state.session
  if session:is_read_only() then
    app().error(('connection `%s` is read-only'):format(session.spec.name))
    return
  end

  local destructive = {}
  for _, info in ipairs(writes) do
    if info.destructive then
      destructive[#destructive + 1] = info
    end
  end
  local gate = #destructive > 0 and state.options.safety.confirm_destructive
    or (#destructive == 0 and state.options.safety.confirm_write)
  if not gate then
    on_confirm()
    return
  end

  local listed = {}
  for _, statement in ipairs(statements) do
    vim.list_extend(listed, confirm.sql_lines(statement))
  end
  local sections = {
    { heading = ('%d statement(s)'):format(#statements), lines = listed, hl = 'DbLensAccent' },
  }
  local flagged = {}
  for _, info in ipairs(destructive) do
    flagged[#flagged + 1] = ('%s %s%s'):format(
      info.verb,
      info.target or '',
      info.whole_object and '  (affects the whole object - no WHERE)' or ''
    )
  end
  if #flagged > 0 then
    sections[#sections + 1] = { heading = 'destructive', lines = flagged, hl = 'DbLensError' }
  end

  local function ask()
    confirm.ask(state.options, {
      title = 'Run write statements',
      danger = #destructive > 0,
      sections = sections,
    }, on_confirm)
  end

  -- Only a single destructive statement has a meaningful estimate to show.
  if #destructive == 1 and session.adapter.caps.estimate_rows then
    session:estimate(destructive[1].sql, function(estimate)
      sections[#sections + 1] = {
        heading = 'estimated rows affected',
        lines = { estimate and tostring(estimate) or 'unavailable' },
        hl = 'DbLensWarn',
      }
      ask()
    end)
    return
  end
  if #destructive > 0 and not session.adapter.caps.estimate_rows then
    sections[#sections + 1] = {
      heading = 'estimated rows affected',
      lines = { ('%s cannot estimate this without running it'):format(session.adapter.label) },
      hl = 'DbLensDim',
    }
  end
  ask()
end

--- Write the current result to a file, choosing the format from the extension.
function M.export(state)
  local result = state.grid.result
  if not result or #result.columns == 0 then
    app().notify('there is no result to export')
    return
  end
  local default = ('%s/%s.csv'):format(
    vim.fn.getcwd(),
    (state.grid.source and state.grid.source.label or 'result'):gsub('%W', '_')
  )
  vim.ui.input({ prompt = 'Export to ', default = default, completion = 'file' }, function(path)
    if not path or vim.trim(path) == '' then
      return
    end
    local format = path:lower():match('%.(%w+)$') == 'json' and 'json' or 'csv'
    local ok, err = export.write(result, path, format)
    if not ok then
      app().error(err)
      return
    end
    app().notify(('exported %d row(s) to %s'):format(#result.rows, path))
  end)
end

return M
