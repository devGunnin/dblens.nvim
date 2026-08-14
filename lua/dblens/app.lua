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
local state_mod = require('dblens.state')
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

--- Bind an async callback to the UI instance that started it.
---
--- Client results land after an unknown delay, by which time the user may have closed dblens,
--- reopened it, or switched connections. Without this every one of those callbacks indexed a
--- module upvalue that was already nil, and closing during a query left the UI unclosable.
---@param fn function
---@return function
local function live(fn)
  local owner = state
  assert(owner ~= nil, 'app.live: nothing to bind the callback to')
  assert(type(fn) == 'function', 'app.live: expected a callback')
  return function(...)
    if state ~= owner then
      return
    end
    return fn(...)
  end
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

--- Record the work the cancel action should reach, unless it already finished.
---@param job dblens.Job
local function track(job)
  assert(type(job) == 'table' and job.cancel, 'app.track: expected a job')
  if state and state.busy and not job.is_done() then
    state.job = job
  end
end

--- Bump the identity of what the grid is showing, so results for the previous view are dropped.
---
--- Sorting and paging keep the epoch: they change the page, not the row set, so a total already
--- in flight is still the right one.
local function new_epoch()
  state.grid.epoch = (state.grid.epoch or 0) + 1
  return state.grid.epoch
end

--- Cancel whatever is running, if anything.
function M.cancel()
  if not state then
    M.notify('nothing is running')
    return
  end
  if state.job then
    state.job.cancel()
    M.notify('cancelled')
    return
  end
  if state.session and state.session:is_busy() then
    state.session:cancel_all()
    M.notify('cancelled')
    return
  end
  M.notify('nothing is running')
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
    --- Resolved once: the winbar redraws on every spinner tick, and re-deriving the set there
    --- allocated a fresh copy 12 times a second.
    icons = require('dblens.ui.icons').get(options.ui.icons),
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
      --- Identity of the current view, and of the current page fetch, so a result that belongs
      --- to a superseded request is dropped instead of overwriting what is on screen.
      epoch = 0,
      fetch = 0,
    },
    history = store or { history = {}, snippets = {} },
    busy = nil,
    job = nil,
  }
end

--- Defined below, after the failure path that owns it.
local start_instance

--- Undo a half-built UI. Without this, an error during `start_instance` left `state` non-nil with
--- no usable layout: `is_open()` said false, `:DbLensClose` reached `layout.close(nil)` and
--- returned success, and every retry stranded another tab of dead scratch buffers.
local function discard_failed_open()
  local failed = state
  state = nil
  if not failed then
    return
  end
  if failed.spinner then
    failed.spinner:stop()
  end
  layout_mod.close(failed.layout)
  pcall(vim.api.nvim_del_augroup_by_name, 'DbLensLifecycle')
end

--- Open the UI. With no name, picks the sole connection, restores, or shows the picker.
---@param name string?
---@param opts { restore: boolean? }?
function M.open(name, opts)
  local options = config.get()
  if M.is_open() then
    if name then
      M.connect(name)
    end
    layout_mod.focus(state.layout, 'sidebar')
    return
  end

  state = build_state(options)
  local ok, err = pcall(start_instance, options)
  if not ok then
    discard_failed_open()
    error(err, 0)
  end

  M.render()
  M.choose_connection(name, opts and opts.restore)
end

--- Build everything a live UI owns: the specs, the layout, the spinner, the pane bindings and
--- the lifecycle autocmds. Called only by `M.open`, which owns the failure path.
function start_instance(options)
  local specs, problems = connections.load(options)
  for _, problem in ipairs(problems) do
    M.error(problem)
  end
  state.specs = specs

  state.layout = layout_mod.open(options)
  state.spinner = status.spinner(
    options,
    live(function()
      require('dblens.ui.results').render_winbar(state)
    end)
  )
  require('dblens.ui.sidebar').attach(state)
  require('dblens.ui.results').attach(state)
  require('dblens.ui.editor').attach(state)

  local group = vim.api.nvim_create_augroup('DbLensLifecycle', { clear = true })
  --- `:q` on one dblens window leaves the rest of the layout stranded and the session, its
  --- resolved secret and any running client alive, so a half-closed layout closes the rest.
  vim.api.nvim_create_autocmd({ 'TabClosed', 'WinClosed' }, {
    group = group,
    callback = function()
      vim.schedule(function()
        if state and not layout_mod.is_open(state.layout) then
          M.close()
        end
      end)
    end,
  })
  --- The sidebar width depends on the terminal width, so a resize has to re-derive it or a
  --- shrunk terminal keeps a sidebar that no longer leaves the grid room to read.
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if state then
        layout_mod.resize(state.layout, state.options)
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      M.save_session()
      if state and state.session then
        state.session:close()
      end
      if state and state.spinner then
        state.spinner:stop()
      end
    end,
  })
end

--- Decide what to connect to when the UI opens.
---
--- Restoring reconnects, so it only happens when the user asked for it: either `:DbLensRestore`
--- or `session.restore = true`.
---@param name string?
---@param force_restore boolean?
function M.choose_connection(name, force_restore)
  if name then
    M.connect(name)
    return
  end
  if (force_restore or state.options.session.restore) and M.restore_saved() then
    return
  end
  if force_restore then
    M.notify('no saved session to restore')
  end

  local specs = state.specs
  if #specs == 0 then
    M.notify('no connections configured - add one with :DbLensAdd')
    return
  end
  if #specs == 1 then
    M.connect(specs[1].name)
    return
  end
  require('dblens.ui.picker').connections(state, function(spec)
    M.connect(spec.name)
  end)
end

--- Reopen the last session, table included.
---@return boolean started, false when there is nothing usable to restore
function M.restore_saved()
  local saved, err = state_mod.load(state.options)
  if err then
    M.error(err)
    return false
  end
  if not saved or not saved.connection then
    return false
  end
  if not connections.find(state.specs, saved.connection) then
    M.notify(('the saved connection `%s` no longer exists'):format(saved.connection))
    return false
  end
  M.connect(saved.connection, function()
    if not saved.relation or not state.session then
      return
    end
    for _, relation in ipairs(state.session.catalog:all_relations()) do
      if relation.name == saved.relation and (relation.schema or '') == (saved.schema or '') then
        M.open_relation(relation)
        return
      end
    end
    M.notify(('`%s` is no longer in the schema'):format(saved.relation))
  end)
  return true
end

--- Remember the connection and table currently open.
function M.save_session()
  if not state or not state.options.session.auto_save then
    return
  end
  local snapshot = state_mod.snapshot(state)
  if not snapshot then
    return
  end
  local ok, err = state_mod.save(state.options, snapshot)
  if not ok then
    M.error(err)
  end
end

--- Close the UI, releasing everything it owns.
---
--- Order matters: the spinner's frame callback renders from `state`, so it has to be stopped
--- while `state` is still the live instance. Stopping it afterwards threw, and everything after
--- the throw — history, the tabpage, the augroup — was skipped, leaving a layout on screen that
--- `is_open` reported as closed and that no later `:DbLensClose` could reach.
function M.close()
  if not state then
    return
  end
  M.save_session()
  if state.spinner then
    state.spinner:stop()
  end
  local closing = state
  state = nil
  if closing.session then
    closing.session:close()
  end
  local saved, err = history.save(closing.history, closing.options)
  if not saved then
    M.error(err)
  end
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
---@param on_ready fun()?  runs once the schema and its first level of relations are loaded
function M.connect(name, on_ready)
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

  new_epoch()
  set_busy('connecting', nil)
  session:connect(live(function(ok, connect_err)
    if not ok then
      set_busy(nil, nil)
      M.error(connect_err)
      return
    end
    state.session = session
    state.tree.expanded[tree.connection_id()] = true
    loader.schemas(
      session,
      live(function(schema_err)
        set_busy(nil, nil)
        if schema_err then
          M.error(schema_err)
          return
        end
        M.expand_default_schema(on_ready)
      end)
    )
  end))
end

--- Expand the first schema so the tree is never a single unhelpful row.
---@param on_done fun()?
function M.expand_default_schema(on_done)
  local session = state.session
  if not session then
    return
  end
  local schemas = session.catalog:schema_list()
  local first = schemas[1]
  if first == nil then
    M.render()
    if on_done then
      on_done()
    end
    return
  end
  if session.catalog.has_schemas then
    state.tree.expanded[tree.schema_id(first)] = true
  end
  M.load_relations(first, on_done)
end

---@param schema string
---@param on_done fun()?
function M.load_relations(schema, on_done)
  local session = state.session
  if not session then
    return
  end
  local id = session.catalog.has_schemas and tree.schema_id(schema) or tree.connection_id()
  state.tree.loading[id] = true
  M.render()
  loader.relations(
    session,
    schema,
    live(function(err)
      state.tree.loading[id] = nil
      if err then
        M.error(err)
      end
      M.render()
      if on_done then
        on_done()
      end
    end)
  )
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
  loader.relation_details(
    session,
    relation,
    live(function(err)
      state.tree.loading[id] = nil
      if err then
        M.error(err)
      end
      M.render()
      if on_done then
        on_done()
      end
    end)
  )
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
  -- Sorting, filtering and paging are properties of a browsed relation. A query result carries
  -- none of them, so they must not survive from whatever was shown before.
  if source.kind ~= 'relation' then
    state.grid.sort = nil
    state.grid.filter = nil
    state.grid.paging = paging.new(state.options.page_size)
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
    -- Not "padded": a SHORT row is padded, a LONG one keeps its extra fields and the grid shows
    -- only the columns it has names for. Naming the wrong repair sent readers hunting for a
    -- padding bug that was not there.
    M.error(
      ('%d row(s) did not match the column count; a value most likely contains the '):format(
        result.malformed
      ) .. 'field separator'
    )
  end
end

--- Fetch the current page of the current relation source.
---
--- A fetch already in flight is cancelled first: two racing page queries used to be resolved by
--- whichever client happened to exit last, which could show page 1 while the pager said page 3.
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

  if state.job and not state.job.is_done() then
    state.job.cancel()
  end
  state.grid.fetch = state.grid.fetch + 1
  local fetch = state.grid.fetch
  set_busy('query', nil)
  local job = session:run(
    statement,
    { columns = columns },
    live(function(result, err)
      if state.grid.fetch ~= fetch then
        return
      end
      set_busy(nil, nil)
      if err then
        state.grid.error = err
        M.render()
        return
      end
      present(result, source)
      M.render()
    end)
  )
  track(job)
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
  new_epoch()
  M.load_relation_details(relation, function()
    state.grid.source = { kind = 'relation', relation = relation, label = relation.name }
    M.fetch_page()
    M.count_rows(relation)
  end)
  layout_mod.focus(state.layout, 'results')
end

--- Whether two relations are the same object. Name alone crosses schemas: on postgres and mysql
--- `public.users` and `staging.users` would share a row count.
local function same_relation(a, b)
  return a ~= nil and b ~= nil and a.name == b.name and (a.schema or '') == (b.schema or '')
end

--- Count a relation, updating the pager once the answer arrives.
---@param relation dblens.Relation
function M.count_rows(relation)
  local session = state.session
  if not session then
    return
  end
  local epoch = state.grid.epoch
  session:run(
    session.adapter.sql.count(relation, state.grid.filter),
    {},
    live(function(result, err)
      if err or not result.rows[1] then
        return
      end
      local count = tonumber(result.rows[1][1])
      session.catalog:set_row_count(relation, count)
      local source = state.grid.source
      -- A count issued before the user filtered or opened something else is not this view's.
      if
        state.grid.epoch == epoch
        and source
        and source.kind == 'relation'
        and same_relation(source.relation, relation)
      then
        state.grid.paging.total = count
      end
      M.render()
    end)
  )
end

---@param delta integer
function M.page(delta)
  local result = state.grid.result
  if not result then
    return
  end
  -- Paging is a property of a browsed relation: `fetch_page` refuses anything else, so stepping
  -- the pager here moved a counter nothing would honour and the key did nothing at all.
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    M.notify('paging needs a table; add LIMIT/OFFSET to the query instead')
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
  new_epoch()
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
    if not session.adapter.caps.explain then
      M.error(('%s has no EXPLAIN dblens can run'):format(session.adapter.label))
      return
    end
    if #statements ~= 1 then
      M.error('EXPLAIN needs exactly one statement')
      return
    end
    statements = { session.adapter.sql.explain(statements[1], opts.analyze == true) }
  end

  -- Classification runs on the text that will actually be SENT, EXPLAIN wrapper included: an
  -- `EXPLAIN ANALYZE` of a DELETE executes the DELETE, and classifying before the wrap made it
  -- look like a read.
  local writes = {}
  for _, statement in ipairs(statements) do
    local info = sqlmod.classify(statement, session.adapter.dialect)
    if info.write then
      writes[#writes + 1] = info
    end
  end
  if #writes > 0 then
    require('dblens.ui.crud').confirm_script(state, statements, writes, function()
      M.execute_statements(statements, trimmed, opts, { confirmed = true })
    end)
    return
  end
  M.execute_statements(statements, trimmed, opts)
end

--- Execute statements that have been through the confirmation gate, and present the last result
--- that has columns. The session gate still re-checks each statement.
---@param approval dblens.WriteApproval?
function M.execute_statements(statements, original, opts, approval)
  local session = state.session
  set_busy('query', nil)
  local job = session:run_script(
    statements,
    { approval = approval },
    live(function(outcomes)
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
      new_epoch()
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
  )
  track(job)
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
  loader.schemas(
    session,
    live(function()
      M.expand_default_schema()
    end)
  )
end

-- ---------------------------------------------------------------------------
-- connection mode

--- Lock the active connection, or open it for editing.
---
--- `locked = nil` toggles. Unlocking is the sanctioned write path: the server stops refusing
--- writes, and the confirmation gate in front of destructive ones is untouched.
---@param locked boolean?
function M.set_locked(locked)
  local session = state and state.session
  if not session then
    M.error('not connected')
    return
  end
  local want = locked
  if want == nil then
    want = not session:is_read_only()
  end
  local ok, err = session:set_locked(want)
  if not ok then
    M.error(err)
    return
  end
  M.notify(
    want and ('`%s` is locked - the server refuses every write'):format(session.spec.name)
      or ('`%s` is open for editing - writes still confirm'):format(session.spec.name)
  )
  M.render()
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
  session:commit(live(function(ok, err, queue_kept)
    set_busy(nil, nil)
    if not ok then
      -- A discarded queue must not leave the grid showing changes as still pending.
      if not queue_kept then
        state.grid.dirty = {}
      end
      M.error(err)
      M.refresh_grid()
      return
    end
    M.notify(('committed %d change(s)'):format(count))
    state.grid.dirty = {}
    M.refresh_grid()
  end))
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
--- Exported so a UI module that starts its own client call binds the result to this instance too.
M.live = live
return M
