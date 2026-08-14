--- The dblens controller: one UI instance, its session, and the state the views draw.
---
--- Views never reach into this module; they are handed an `actions` table at bind time and a
--- read-only look at `state` at render time. Dependencies therefore point one way — app to view —
--- which is what keeps the views replaceable and this module the only place state changes.
local config = require('dblens.config')
local connections = require('dblens.connections')
local grid = require('dblens.render.grid')
local history = require('dblens.history')
local layout_mod = require('dblens.ui.layout')
local loader = require('dblens.loader')
local paging = require('dblens.paging')
local session_mod = require('dblens.session')
local sqlmod = require('dblens.sql')
local status = require('dblens.ui.status')
local tree = require('dblens.tree')

local M = {}

--- The single live UI. `nil` when dblens is closed.
---@class dblens.State
local state = nil

function M.state()
  return state
end

function M.is_open()
  return state ~= nil and layout_mod.is_open(state.layout)
end

---@param message string
---@param level integer?
function M.notify(message, level)
  vim.notify('dblens: ' .. message, level or vim.log.levels.INFO)
end

function M.error(message)
  M.notify(message, vim.log.levels.ERROR)
end

--- Render every pane that currently exists.
function M.render()
  if not M.is_open() then
    return
  end
  require('dblens.ui.sidebar').render(state)
  require('dblens.ui.results').render(state)
  require('dblens.ui.editor').render(state)
end

--- Mark work as in flight, driving the spinner and the winbar.
local function set_busy(label, job)
  state.busy = label
  state.job = job
  if label then
    state.spinner:start()
  else
    state.spinner:stop()
  end
  M.render()
end

--- Cancel whatever is running, if anything.
function M.cancel()
  if not state or not state.job then
    M.notify('nothing is running')
    return
  end
  state.job.cancel()
  M.notify('cancelled')
end

-- ---------------------------------------------------------------------------
-- lifecycle

local function build_state(options)
  local store, err = history.load(options)
  if err then
    M.error(err)
  end
  return {
    options = options,
    layout = nil,
    session = nil,
    specs = {},
    tree = { expanded = {}, loading = {}, nodes = {} },
    grid = {
      source = nil,
      result = nil,
      paging = paging.new(options.page_size),
      sort = nil,
      filter = nil,
      spans = {},
      types = nil,
      dirty = {},
      message = nil,
      error = nil,
      truncated = false,
      elapsed_ms = nil,
    },
    history = store or { history = {}, snippets = {} },
    busy = nil,
    job = nil,
  }
end

--- Open the UI. With no name, picks the sole connection or shows the picker.
---@param name string?
function M.open(name)
  local options = config.get()
  if M.is_open() then
    if name then
      M.connect(name)
    end
    layout_mod.focus(state.layout, 'sidebar')
    return
  end

  state = build_state(options)
  local specs, problems = connections.load(options)
  for _, problem in ipairs(problems) do
    M.error(problem)
  end
  state.specs = specs

  state.layout = layout_mod.open(options)
  state.spinner = status.spinner(options, function()
    require('dblens.ui.results').render_winbar(state)
  end)
  require('dblens.ui.sidebar').attach(state)
  require('dblens.ui.results').attach(state)
  require('dblens.ui.editor').attach(state)

  vim.api.nvim_create_autocmd('TabClosed', {
    group = vim.api.nvim_create_augroup('DbLensLifecycle', { clear = true }),
    callback = function()
      if state and not layout_mod.is_open(state.layout) then
        M.close()
      end
    end,
  })

  M.render()
  if name then
    M.connect(name)
  elseif #specs == 1 then
    M.connect(specs[1].name)
  elseif #specs == 0 then
    M.notify('no connections configured - add one with :DbLensAdd')
  else
    require('dblens.ui.picker').connections(state, function(spec)
      M.connect(spec.name)
    end)
  end
end

function M.close()
  if not state then
    return
  end
  local closing = state
  state = nil
  if closing.session then
    closing.session:close()
  end
  if closing.spinner then
    closing.spinner:stop()
  end
  history.save(closing.history, closing.options)
  layout_mod.close(closing.layout)
  pcall(vim.api.nvim_del_augroup_by_name, 'DbLensLifecycle')
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- ---------------------------------------------------------------------------
-- connection

--- Connect by name, replacing any current session.
---@param name string
function M.connect(name)
  if not M.is_open() then
    M.open(name)
    return
  end
  local spec = connections.find(state.specs, name)
  if not spec then
    M.error(('no connection named `%s`'):format(name))
    return
  end

  if state.session then
    state.session:close()
    state.session = nil
  end
  state.tree = { expanded = {}, loading = {}, nodes = {} }
  state.grid =
    vim.tbl_extend('force', state.grid, { source = nil, result = nil, error = nil, message = nil })

  local session, err = session_mod.new(spec, state.options)
  if not session then
    M.error(err)
    return
  end

  set_busy('connecting', nil)
  session:connect(function(ok, connect_err)
    if not ok then
      set_busy(nil, nil)
      M.error(connect_err)
      return
    end
    state.session = session
    state.tree.expanded[tree.connection_id()] = true
    loader.schemas(session, function(schema_err)
      set_busy(nil, nil)
      if schema_err then
        M.error(schema_err)
        return
      end
      M.expand_default_schema()
    end)
  end)
end

--- Expand the first schema so the tree is never a single unhelpful row.
function M.expand_default_schema()
  local session = state.session
  if not session then
    return
  end
  local schemas = session.catalog:schema_list()
  local first = schemas[1]
  if first == nil then
    M.render()
    return
  end
  if session.catalog.has_schemas then
    state.tree.expanded[tree.schema_id(first)] = true
  end
  M.load_relations(first)
end

---@param schema string
function M.load_relations(schema)
  local session = state.session
  if not session then
    return
  end
  local id = session.catalog.has_schemas and tree.schema_id(schema) or tree.connection_id()
  state.tree.loading[id] = true
  M.render()
  loader.relations(session, schema, function(err)
    state.tree.loading[id] = nil
    if err then
      M.error(err)
    end
    M.render()
  end)
end

---@param relation dblens.Relation
---@param on_done fun()?
function M.load_relation_details(relation, on_done)
  local session = state.session
  if not session then
    return
  end
  local id = tree.relation_id(relation)
  state.tree.loading[id] = true
  M.render()
  loader.relation_details(session, relation, function(err)
    state.tree.loading[id] = nil
    if err then
      M.error(err)
    end
    M.render()
    if on_done then
      on_done()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- results

local function relation_types(relation)
  local info = state.session.catalog:info_for(relation)
  if not info.columns then
    return nil
  end
  local by_name = {}
  for _, column in ipairs(info.columns) do
    by_name[column.name] = column.type
  end
  return by_name
end

--- Column types aligned to the result's column order, for type-aware rendering.
local function types_for(result, relation)
  if not relation then
    return nil
  end
  local by_name = relation_types(relation)
  if not by_name then
    return nil
  end
  local out = {}
  for index, name in ipairs(result.columns) do
    out[index] = by_name[name] or ''
  end
  return out
end

--- Store a result and lay it out. `source` describes where the rows came from.
local function present(result, source, extra)
  local truncated = false
  if #result.rows > state.options.max_rows then
    -- Truncate what we render, never the user's SQL.
    for index = #result.rows, state.options.max_rows + 1, -1 do
      result.rows[index] = nil
    end
    truncated = true
  end
  state.grid.source = source
  state.grid.result = result
  state.grid.types = types_for(result, source.relation)
  state.grid.dirty = {}
  state.grid.error = nil
  state.grid.truncated = truncated or result.truncated
  state.grid.elapsed_ms = result.elapsed_ms
  state.grid.message = extra and extra.message or nil
  if result.malformed > 0 then
    M.error(('%d row(s) did not match the column count and were padded'):format(result.malformed))
  end
end

--- Fetch the current page of the current relation source.
function M.fetch_page()
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    return
  end
  local session = state.session
  local statement = session.adapter.sql.page(source.relation, {
    limit = state.grid.paging.size,
    offset = paging.offset(state.grid.paging),
    order_by = state.grid.sort,
    where = state.grid.filter,
  })
  local columns = {}
  for _, column in ipairs(session.catalog:info_for(source.relation).columns or {}) do
    columns[#columns + 1] = column.name
  end

  local job = session:run(statement, { columns = columns }, function(result, err)
    set_busy(nil, nil)
    if err then
      state.grid.error = err
      M.render()
      return
    end
    present(result, source)
    M.render()
  end)
  set_busy('query', job)
end

--- Open a relation in the grid: load its columns, count it, then show page 1.
---@param relation dblens.Relation
function M.open_relation(relation)
  if not state.session then
    return
  end
  state.grid.paging = paging.new(state.options.page_size)
  state.grid.sort = nil
  state.grid.filter = nil
  M.load_relation_details(relation, function()
    state.grid.source = { kind = 'relation', relation = relation, label = relation.name }
    M.fetch_page()
    M.count_rows(relation)
  end)
  layout_mod.focus(state.layout, 'results')
end

--- Count a relation, updating the pager once the answer arrives.
---@param relation dblens.Relation
function M.count_rows(relation)
  local session = state.session
  if not session then
    return
  end
  session:run(session.adapter.sql.count(relation, state.grid.filter), {}, function(result, err)
    if err or not result.rows[1] then
      return
    end
    local count = tonumber(result.rows[1][1])
    session.catalog:set_row_count(relation, count)
    local source = state.grid.source
    if source and source.kind == 'relation' and source.relation.name == relation.name then
      state.grid.paging.total = count
    end
    M.render()
  end)
end

---@param delta integer
function M.page(delta)
  local result = state.grid.result
  if not result then
    return
  end
  local moved
  state.grid.paging, moved = paging.step(state.grid.paging, delta, #result.rows)
  if not moved then
    M.notify(delta > 0 and 'last page' or 'first page')
    return
  end
  M.fetch_page()
end

--- Sort server-side by a column, cycling ascending -> descending -> unsorted.
---@param column string
function M.sort_by(column)
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    M.notify('sorting needs a table; run the query with an ORDER BY instead')
    return
  end
  local current = state.grid.sort
  if not current or current.column ~= column then
    state.grid.sort = { column = column, desc = false }
  elseif not current.desc then
    state.grid.sort = { column = column, desc = true }
  else
    state.grid.sort = nil
  end
  state.grid.paging.page = 1
  M.fetch_page()
end

--- Apply a WHERE predicate to the current relation.
---@param where string
function M.set_filter(where)
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    M.notify('filtering needs a table; add a WHERE to the query instead')
    return
  end
  local trimmed = vim.trim(where)
  local problem =
    require('dblens.adapters.common').check_predicate(trimmed, state.session.adapter.dialect)
  if problem then
    M.error(problem)
    return
  end
  state.grid.filter = trimmed ~= '' and trimmed or nil
  state.grid.paging = paging.new(state.options.page_size)
  M.fetch_page()
  M.count_rows(source.relation)
end

function M.refresh_grid()
  local source = state.grid.source
  if not source then
    return
  end
  if source.kind == 'relation' then
    M.fetch_page()
    M.count_rows(source.relation)
    return
  end
  M.run_sql(source.sql, { label = source.label })
end

-- ---------------------------------------------------------------------------
-- queries

--- Run SQL from the editor. Multiple statements run in order and stop at the first error.
---@param text string
---@param opts { label: string?, explain: boolean?, analyze: boolean? }?
function M.run_sql(text, opts)
  opts = opts or {}
  local session = state.session
  if not session then
    M.error('not connected')
    return
  end
  local trimmed = vim.trim(text or '')
  if trimmed == '' then
    M.notify('nothing to run')
    return
  end

  local statements = {}
  for _, entry in ipairs(sqlmod.split(trimmed, session.adapter.dialect)) do
    statements[#statements + 1] = vim.trim(entry.sql)
  end
  if #statements == 0 then
    M.notify('nothing to run')
    return
  end
  if opts.explain then
    if #statements ~= 1 then
      M.error('EXPLAIN needs exactly one statement')
      return
    end
    statements = { session.adapter.sql.explain(statements[1], opts.analyze == true) }
  end

  local writes = {}
  for _, statement in ipairs(statements) do
    local info = sqlmod.classify(statement, session.adapter.dialect)
    if info.write then
      writes[#writes + 1] = info
    end
  end
  if #writes > 0 then
    require('dblens.ui.crud').confirm_script(state, statements, writes, function()
      M.execute_statements(statements, trimmed, opts)
    end)
    return
  end
  M.execute_statements(statements, trimmed, opts)
end

--- Execute already-vetted statements and present the last result that has columns.
function M.execute_statements(statements, original, opts)
  local session = state.session
  set_busy('query', nil)
  session:run_script(statements, function(outcomes)
    set_busy(nil, nil)
    local last = outcomes[#outcomes]
    if last and last.err then
      state.grid.error = last.err
      state.grid.source = { kind = 'query', sql = original, label = opts.label or 'query' }
      state.grid.result = nil
      M.render()
      return
    end
    if state.options.history.enabled then
      history.record(state.history, session.spec.name, original)
    end

    local shown, total_ms = nil, 0
    for _, outcome in ipairs(outcomes) do
      total_ms = total_ms + (outcome.result and outcome.result.elapsed_ms or 0)
      if outcome.result and #outcome.result.columns > 0 then
        shown = outcome.result
      end
    end
    if not shown then
      state.grid.source = { kind = 'query', sql = original, label = opts.label or 'query' }
      state.grid.result = { columns = {}, rows = {}, malformed = 0 }
      state.grid.error = nil
      state.grid.elapsed_ms = total_ms
      state.grid.message = ('%d statement(s) ran, no rows returned'):format(#outcomes)
      M.render()
      M.refresh_after_write(statements)
      return
    end
    shown.elapsed_ms = total_ms
    present(shown, { kind = 'query', sql = original, label = opts.label or 'query' })
    M.render()
    M.refresh_after_write(statements)
  end)
end

--- After an ad-hoc write, the schema and any open table may be stale.
function M.refresh_after_write(statements)
  local session = state.session
  local touched = false
  for _, statement in ipairs(statements) do
    if sqlmod.classify(statement, session.adapter.dialect).write then
      touched = true
    end
  end
  if not touched then
    return
  end
  session.catalog:clear()
  state.tree.expanded[tree.connection_id()] = true
  loader.schemas(session, function()
    M.expand_default_schema()
  end)
end

-- ---------------------------------------------------------------------------
-- transactions

function M.txn_begin()
  local session = state and state.session
  if not session then
    M.error('not connected')
    return
  end
  if session:is_read_only() then
    M.error(('connection `%s` is read-only'):format(session.spec.name))
    return
  end
  local ok, err = session.txn:begin()
  if not ok then
    M.error(err)
    return
  end
  M.notify('transaction started - changes are queued until you commit')
  M.render()
end

function M.txn_commit()
  local session = state and state.session
  if not session then
    return
  end
  local count = session.txn:count()
  set_busy('commit', nil)
  session:commit(function(ok, err)
    set_busy(nil, nil)
    if not ok then
      M.error(err)
      return
    end
    M.notify(('committed %d change(s)'):format(count))
    state.grid.dirty = {}
    M.refresh_grid()
  end)
end

function M.txn_rollback()
  local session = state and state.session
  if not session or not session.txn:is_active() then
    M.notify('no transaction is open')
    return
  end
  local count = session.txn:count()
  session.txn:reset()
  state.grid.dirty = {}
  M.notify(('rolled back %d queued change(s)'):format(count))
  M.refresh_grid()
end

-- ---------------------------------------------------------------------------
-- geometry helpers shared with the views

--- Recompute the grid layout for the current result.
---@return dblens.GridOutput?
function M.grid_output()
  local result = state.grid.result
  if not result or #result.columns == 0 then
    return nil
  end
  local ui = state.options.ui
  return grid.render({
    columns = result.columns,
    rows = result.rows,
    types = state.grid.types,
    max_col_width = ui.grid.max_col_width,
    null_display = ui.grid.null_display,
    separator = ui.grid.separator,
    truncation = ui.grid.truncation,
    sort = state.grid.sort,
    dirty = state.grid.dirty,
  })
end

M.set_busy = set_busy
return M
