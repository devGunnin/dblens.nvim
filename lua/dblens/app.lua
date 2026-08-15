--- The dblens controller: one UI instance, its session, and the state the views draw.
---
--- Views never reach into this module; they are handed an `actions` table at bind time and a
--- read-only look at `state` at render time. Dependencies therefore point one way — app to view —
--- which is what keeps the views replaceable and this module the only place state changes.
local common = require('dblens.adapters.common')
local config = require('dblens.config')
local connections = require('dblens.connections')
local fk = require('dblens.fk')
local grid_mod = require('dblens.render.grid')
local history = require('dblens.history')
local layout_mod = require('dblens.ui.layout')
local loader = require('dblens.loader')
local paging = require('dblens.paging')
local protocol = require('dblens.protocol')
local search_mod = require('dblens.search')
local session_mod = require('dblens.session')
local state_mod = require('dblens.state')
local sqlmod = require('dblens.sql')
local status = require('dblens.ui.status')
local tabs = require('dblens.tabs')
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

--- Bump the identity of what a tab is showing, so results for its previous view are dropped.
---
--- Sorting and paging keep the epoch: they change the page, not the row set, so a total already
--- in flight is still the right one.
---@param grid table  the tab this view belongs to
local function new_epoch(grid)
  assert(type(grid) == 'table', 'app.new_epoch: expected a grid state')
  grid.epoch = (grid.epoch or 0) + 1
  return grid.epoch
end

--- Claim the next fetch token for a tab. A result carrying a token the tab has moved past belongs
--- to a superseded request, so it is dropped rather than drawn over what replaced it.
---@param grid table
---@return integer
local function new_fetch(grid)
  assert(type(grid) == 'table', 'app.new_fetch: expected a grid state')
  grid.fetch = grid.fetch + 1
  return grid.fetch
end

--- Point `state.grid` at the active tab. The ONE place it is repointed, so it can never disagree
--- with `state.tabs.active` — every reader of `state.grid` is reading the tab on screen.
local function activate(index)
  assert(tabs.select(state.tabs, index), ('app.activate: no tab %s'):format(tostring(index)))
  state.grid = tabs.active(state.tabs)
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
  local open_tabs = tabs.new(options)
  return {
    options = options,
    --- Resolved once: the winbar redraws on every spinner tick, and re-deriving the set there
    --- allocated a fresh copy 12 times a second.
    icons = require('dblens.ui.icons').get(options.ui.icons),
    layout = nil,
    session = nil,
    specs = {},
    --- Passwords discovery read out of a workspace file, by connection name. Memory only, for as
    --- long as this UI is open: no spec carries them, so nothing can write them anywhere.
    secrets = {},
    discovering = false,
    tree = { expanded = {}, loading = {}, nodes = {} },
    --- Every open result, each with its own guards; `dblens.tabs` owns the shape.
    tabs = open_tabs,
    --- The tab on screen. A pointer into `tabs.list`, repointed only by `activate`.
    grid = tabs.active(open_tabs),
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
---@param opts { restore: boolean?, discover: boolean? }?
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
  M.choose_connection(name, opts)
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
---@param opts { restore: boolean?, discover: boolean? }?
function M.choose_connection(name, opts)
  opts = opts or {}
  if name then
    M.connect(name)
    return
  end
  if opts.discover then
    M.discover()
    return
  end
  if (opts.restore or state.options.session.restore) and M.restore_saved() then
    return
  end
  if opts.restore then
    M.notify('no saved session to restore')
  end

  local specs = state.specs
  if #specs == 0 then
    -- Nothing configured is the case discovery exists for: offer what the project has instead of
    -- a dead end. It still only OFFERS — the user picks, and nothing is scanned until now.
    if state.options.discovery.auto then
      M.discover()
      return
    end
    M.notify('no connections configured - add one with :DbLensAdd or :DbLensDiscover')
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

--- Said once, on connecting a LOCKED connection whose lock is not the engine's own refusal.
---
--- The sidebar, winbar and statusline all print `LOCKED` identically on every engine, and on SQL
--- Server that word is a client-side verb blocklist rather than a promise. A user who never runs
--- `:checkhealth` would otherwise never learn the difference. Not a startup notification: it
--- fires only for the connection it is true of, and only when that connection is opened locked.
local function warn_if_best_effort(session)
  local enforcement = session.adapter.read_only_enforcement
  if not session:is_read_only() or enforcement.strength == 'strong' then
    return
  end
  M.notify(
    ('`%s`: LOCKED is best-effort here - dblens refuses the writes it recognises, the '):format(
      session.spec.name
    )
      .. 'server does not. Connect as a read-only login for a hard boundary '
      .. '(:h dblens-safety-mssql)',
    vim.log.levels.WARN
  )
end

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
  -- Every open result belongs to the connection it was read from, so switching connections starts
  -- from one empty tab rather than leaving rows on screen that the new database may not hold.
  M.cancel_tab_jobs()
  state.tabs = tabs.new(state.options)
  activate(1)

  -- Only a discovered connection has a secret held here: every other spec resolves its own from
  -- the reference it carries, and nothing but discovery ever puts a value in this table.
  local secret = spec.source == 'discovered' and state.secrets[spec.name] or nil
  local session, err = session_mod.new(spec, state.options, { secret = secret })
  if not session then
    M.error(err)
    return
  end

  new_epoch(state.grid)
  set_busy('connecting', nil)
  session:connect(live(function(ok, connect_err)
    if not ok then
      set_busy(nil, nil)
      M.error(connect_err)
      return
    end
    state.session = session
    warn_if_best_effort(session)
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
-- discovery

--- Put a discovered spec in the live list, replacing the one a previous scan left under the same
--- name. A collision with a CONFIGURED connection is refused: `:DbLens name` must never open a
--- different database than the name has always meant.
---@param spec dblens.ConnectionSpec
---@return string? error
local function adopt_discovered(spec)
  for index, existing in ipairs(state.specs) do
    if existing.name == spec.name then
      if existing.source ~= 'discovered' then
        return ('a connection named `%s` already exists'):format(spec.name)
      end
      state.specs[index] = spec
      return nil
    end
  end
  state.specs[#state.specs + 1] = spec
  return nil
end

--- Names a scan must not hand out. A rescan legitimately finds the same databases again, so a
--- discovered connection does not reserve its own name; every other one does.
---@return string[]
local function reserved_names()
  local taken = {}
  for _, spec in ipairs(state.specs) do
    if spec.source ~= 'discovered' then
      taken[#taken + 1] = spec.name
    end
  end
  return taken
end

--- Show what a finished scan found, or say why there is nothing to show.
---@param candidates dblens.Candidate[]
---@param report dblens.DiscoveryReport
local function offer(candidates, report)
  local root = vim.fn.fnamemodify(report.root, ':~')
  -- A drop is never silent: a workspace file describing something dblens refuses to open (a path
  -- above the root, a value a client would read as an option) is exactly what a user wants told.
  if report.skipped > 0 then
    M.notify(
      ('%d thing%s this project describes could not be offered safely'):format(
        report.skipped,
        report.skipped == 1 and '' or 's'
      )
    )
  end
  if #candidates == 0 then
    M.notify(('found no databases under %s - add one with :DbLensAdd'):format(root))
    return
  end
  -- A bounded scan that stopped early has found SOME of them, and saying so is the difference
  -- between "your project has these" and "these are the ones it got to".
  if report.stats.truncated then
    M.notify(('the scan of %s hit its limit, so this may not be all of them'):format(root))
  end
  require('dblens.ui.picker').discovered(state, candidates, report)
end

--- Scan the workspace and offer what it finds.
---
--- On-demand only: nothing here runs at startup or from `setup{}`, nothing is connected without
--- the user picking it, and what is picked opens LOCKED like every other connection.
function M.discover()
  if not M.is_open() then
    M.open(nil, { discover = true })
    return
  end
  if state.discovering then
    M.notify('already looking for databases in this project')
    return
  end
  local discovery = require('dblens.discovery')
  state.discovering = true
  set_busy('discovering', nil)
  local job = discovery.scan(
    {
      root = discovery.root(),
      taken = reserved_names(),
      bounds = {
        max_depth = state.options.discovery.max_depth,
        max_entries = state.options.discovery.max_entries,
      },
    },
    live(function(candidates, report)
      state.discovering = false
      set_busy(nil, nil)
      if report.stats.error then
        M.error(report.stats.error)
        return
      end
      if not report.stats.cancelled then
        offer(candidates, report)
      end
    end)
  )
  track(job)
end

--- Connect to something discovery found.
---
--- Session-only, by design: the spec joins THIS UI's connection list and is never written to the
--- connections file, and a password found in a `.env` stays in `state.secrets` until dblens
--- closes. To keep a discovered connection, save it with `:DbLensAdd`, which asks where its
--- password comes from rather than storing one.
---@param candidate dblens.Candidate
function M.connect_discovered(candidate)
  local spec = require('dblens.discovery').to_spec(candidate)
  local problem = connections.validate(spec)
  if problem then
    M.error(problem)
    return
  end
  problem = adopt_discovered(spec)
  if problem then
    M.error(problem)
    return
  end
  state.secrets[spec.name] = candidate.secret
  M.connect(spec.name)
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

--- Store a result in ONE tab and lay it out. `source` describes where the rows came from.
---
--- The tab is passed in rather than read from `state`: the rows belong to the tab that asked for
--- them, which may no longer be the one on screen.
---@param grid table
local function present(grid, result, source, extra)
  assert(type(grid) == 'table', 'app.present: expected the tab the rows belong to')
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
    grid.sort = nil
    grid.filter = nil
    grid.paging = paging.new(state.options.page_size)
  end
  grid.source = source
  grid.result = result
  grid.types = types_for(result, source.relation)
  grid.dirty = {}
  -- Matches are row/column positions in the rows being replaced, so they cannot survive them.
  grid.search = nil
  grid.error = nil
  grid.truncated = truncated or result.truncated
  grid.elapsed_ms = result.elapsed_ms
  grid.message = extra and extra.message or nil
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

--- Fetch the current page of one tab's relation source.
---
--- That tab's own fetch already in flight is cancelled first: two racing page queries used to be
--- resolved by whichever client happened to exit last, which could show page 1 while the pager
--- said page 3. Only THIS tab's fetch is cancelled — another tab's query is not this one's to end.
---@param grid table  the tab to fetch into
local function fetch_page_into(grid)
  assert(type(grid) == 'table', 'app.fetch_page_into: expected a grid state')
  local source = grid.source
  if not source or source.kind ~= 'relation' then
    return
  end
  local session = state.session
  local statement = session.adapter.sql.page(source.relation, {
    limit = grid.paging.size,
    offset = paging.offset(grid.paging),
    order_by = grid.sort,
    where = grid.filter,
  })
  local columns = {}
  for _, column in ipairs(session.catalog:info_for(source.relation).columns or {}) do
    columns[#columns + 1] = column.name
  end

  if grid.job and not grid.job.is_done() then
    grid.job.cancel()
  end
  local fetch = new_fetch(grid)
  set_busy('query', nil)
  local job = session:run(
    statement,
    { columns = columns },
    live(function(result, err)
      if grid.fetch ~= fetch then
        return
      end
      set_busy(nil, nil)
      if err then
        grid.error = err
        M.render()
        return
      end
      present(grid, result, source)
      M.render()
      -- Past the end. Without a row count the pager cannot clamp a jump — a full page is all it
      -- knows — so `gp 500` lands here, and a bare `0 rows` winbar looks like an empty table.
      if #result.rows == 0 and grid.paging.page > 1 then
        M.notify(
          ('page %d is past the end of this result - `[P` goes back to the first page'):format(
            grid.paging.page
          )
        )
      end
    end)
  )
  grid.job = job
  track(job)
end

--- Fetch the current page of the tab on screen.
function M.fetch_page()
  fetch_page_into(state.grid)
end

--- Open a relation in the grid: load its columns, count it, then show page 1.
---
--- `opts.filter` opens the table already narrowed — how foreign-key navigation lands on the
--- referenced row. It must already have been through `check_predicate`; the assertion here is
--- the second lock on the same door, because `common.page` would otherwise raise deep in SQL
--- generation with no clue as to who supplied it.
---@param relation dblens.Relation
---@param opts { filter: string?, origin: string?, new_tab: boolean? }?
---   origin: where the navigation came from; new_tab: show it beside the current result
function M.open_relation(relation, opts)
  opts = opts or {}
  if not state.session then
    return
  end
  assert(
    opts.filter == nil or common.check_predicate(opts.filter, state.session.adapter.dialect) == nil,
    'app.open_relation: an unvetted predicate reached the grid'
  )
  if opts.new_tab and not M.open_tab() then
    return
  end
  -- Captured now: the rows belong to this tab even if the user switches away while they load.
  local grid = state.grid
  grid.paging = paging.new(state.options.page_size)
  grid.sort = nil
  grid.filter = opts.filter
  new_epoch(grid)
  M.load_relation_details(relation, function()
    grid.source = {
      kind = 'relation',
      relation = relation,
      label = relation.name,
      origin = opts.origin,
    }
    fetch_page_into(grid)
    M.count_rows(relation, grid.filter, grid)
  end)
  layout_mod.focus(state.layout, 'results')
end

--- Whether two relations are the same object. Name alone crosses schemas: on postgres and mysql
--- `public.users` and `staging.users` would share a row count.
local function same_relation(a, b)
  return a ~= nil and b ~= nil and a.name == b.name and (a.schema or '') == (b.schema or '')
end

--- Count a relation, updating the pager once the answer arrives.
---
--- The predicate is passed IN rather than read from the grid. It used to be read from there, so
--- counting a table from the tree applied whatever WHERE the grid happened to be showing for a
--- DIFFERENT table — either erroring on an unknown column, or storing a wrong count as that
--- table's own. For the same reason only an unfiltered count is cached in the catalog: a
--- filtered total belongs to one view, not to the table.
---@param relation dblens.Relation
---@param where string?  -- the predicate this count is for; nil counts the whole relation
---@param into table?    -- the tab the total belongs to; the one on screen by default
function M.count_rows(relation, where, into)
  local session = state.session
  if not session then
    return
  end
  local grid = into or state.grid
  local epoch = grid.epoch
  session:run(
    session.adapter.sql.count(relation, where),
    {},
    live(function(result, err)
      if err or not result.rows[1] then
        return
      end
      local count = tonumber(result.rows[1][1])
      if where == nil then
        session.catalog:set_row_count(relation, count)
      end
      local source = grid.source
      -- A count issued before that tab filtered or opened something else is not its view's.
      if
        grid.epoch == epoch
        and source
        and source.kind == 'relation'
        and same_relation(source.relation, relation)
      then
        grid.paging.total = count
      end
      M.render()
    end)
  )
end

--- The result the pager applies to, or nil after saying why it does not.
---
--- Paging is a property of a browsed relation: `fetch_page` refuses anything else, so stepping
--- the pager for a query result moved a counter nothing would honour and the key did nothing.
---@return dblens.ResultSet?
local function paged_result()
  local result = state.grid.result
  if not result then
    return nil
  end
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    M.notify('paging needs a table; add LIMIT/OFFSET to the query instead')
    return nil
  end
  return result
end

---@param delta integer
function M.page(delta)
  local result = paged_result()
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

--- Jump straight to a page. Out of range is clamped by the pager, not sent to the server.
---@param page integer  -- 1-based
function M.goto_page(page)
  assert(type(page) == 'number' and page == math.floor(page), 'app.goto_page: expected an integer')
  local result = paged_result()
  if not result then
    return
  end
  if page < 1 then
    M.notify('pages start at 1')
    return
  end
  local moved
  state.grid.paging, moved = paging.goto_page(state.grid.paging, page, #result.rows)
  if not moved then
    M.notify(('already on page %d'):format(state.grid.paging.page))
    return
  end
  M.fetch_page()
end

--- Jump to the first or the last page.
---@param which 'first'|'last'
function M.page_edge(which)
  assert(which == 'first' or which == 'last', 'app.page_edge: expected `first` or `last`')
  if not paged_result() then
    return
  end
  if which == 'first' then
    M.goto_page(1)
    return
  end
  -- Without a total there is no last page to jump to, only a next one to step towards.
  local pages = paging.page_count(state.grid.paging)
  if not pages then
    M.notify('the row count is not known yet, so neither is the last page')
    return
  end
  M.goto_page(pages)
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
  local problem = common.check_predicate(trimmed, state.session.adapter.dialect)
  if problem then
    M.error(problem)
    return
  end
  state.grid.filter = trimmed ~= '' and trimmed or nil
  state.grid.paging = paging.new(state.options.page_size)
  new_epoch(state.grid)
  M.fetch_page()
  M.count_rows(source.relation, state.grid.filter)
end

--- A predicate comparing a column to a cell value, refused early with a reason the user can act
--- on rather than left to fail as something else further down.
---
--- The value is QUOTED, never spliced, and the predicate is vetted exactly like a typed one. The
--- extra check is the lock: a locked run must be PROVABLY one statement, and that proof is a byte
--- scan that deliberately does not read quoting — so a `;` inside the value makes the run
--- unprovable however correctly it is escaped, and the gate would refuse it with a message about
--- multiple statements that says nothing about the cell the user was pointing at.
---@return string? predicate, string? error
local function cell_predicate(session, column, value, op)
  local predicate, problem = common.cell_predicate(column, value, op, session.adapter.dialect)
  if not predicate then
    return nil, problem
  end
  if session:is_read_only() and predicate:find(';', 1, true) then
    return nil,
      ('this value contains a `;`, and `%s` is LOCKED, so the run cannot be proved to be one '):format(
        session.spec.name
      ) .. 'statement. Unlock with `:DbLensWrite` (<leader>dw) to use it.'
  end
  return predicate, nil
end

--- Filter the browsed table to (or away from) the value under the cursor.
---@param cell dblens.Cell
---@param op '='|'<>'
function M.filter_by_cell(cell, op)
  local source = state.grid.source
  if not state.session then
    M.error('not connected')
    return
  end
  if not source or source.kind ~= 'relation' then
    M.notify('filtering needs a table; add a WHERE to the query instead')
    return
  end
  local predicate, problem = cell_predicate(state.session, cell.name, cell.value, op)
  if not predicate then
    M.error(problem)
    return
  end
  M.set_filter(predicate)
end

function M.clear_filter()
  if not state.grid.filter then
    M.notify('no filter is applied')
    return
  end
  M.set_filter('')
end

function M.refresh_grid()
  local source = state.grid.source
  if not source then
    return
  end
  if source.kind == 'relation' then
    M.fetch_page()
    M.count_rows(source.relation, state.grid.filter)
    return
  end
  M.run_sql(source.sql, { label = source.label })
end

-- ---------------------------------------------------------------------------
-- result tabs

--- Stop every tab's in-flight client call. Used when the whole tab set is being replaced.
function M.cancel_tab_jobs()
  for _, grid in ipairs(state.tabs.list) do
    if grid.job and not grid.job.is_done() then
      grid.job.cancel()
    end
  end
end

--- Open an empty result tab and show it.
---@return boolean opened  -- false when the cap refused it, which is reported here
function M.open_tab()
  local index, err = tabs.open(state.tabs, state.options, state.options.ui.results.max_tabs)
  if not index then
    M.notify(err)
    return false
  end
  activate(index)
  M.render()
  return true
end

--- Close the result tab on screen, cancelling whatever it was running.
function M.close_tab()
  local retired = state.grid
  if retired.job and not retired.job.is_done() then
    retired.job.cancel()
  end
  local removed = tabs.close(state.tabs, state.options)
  activate(state.tabs.active)
  M.render()
  M.notify(
    removed and ('closed - %d result tab(s) left'):format(tabs.count(state.tabs))
      or 'closed the last result'
  )
end

--- Show the next or previous tab, wrapping.
---@param delta integer
function M.step_tab(delta)
  if tabs.count(state.tabs) == 1 then
    M.notify('only one result is open')
    return
  end
  activate(tabs.step(state.tabs, delta))
  M.render()
end

--- Show the tab at `index`, 1-based.
---@param index integer
function M.select_tab(index)
  if not tabs.select(state.tabs, index) then
    M.notify(('there is no result tab %s'):format(tostring(index)))
    return
  end
  activate(index)
  M.render()
end

-- ---------------------------------------------------------------------------
-- foreign-key navigation

--- The catalog's record of one column of the relation currently browsed.
---@return dblens.Column?
local function column_info(session, relation, name)
  for _, column in ipairs(session.catalog:info_for(relation).columns or {}) do
    if column.name == name then
      return column
    end
  end
  return nil
end

--- The sole primary-key column of a relation, or nil when it has none or several.
---@return string?
local function lone_primary_key(catalog, relation)
  local pk = catalog:primary_key(relation)
  return #pk == 1 and pk[1].name or nil
end

--- Browse the referenced table, narrowed to the referenced row.
---@param from dblens.Relation
---@param cell dblens.Cell
---@param target dblens.FkTarget
local function open_fk_target(from, cell, target)
  local session = state.session
  local relation = fk.resolve(session.catalog, from, target.table, target.schema)
  if not relation then
    local named = target.schema and ('%s.%s'):format(target.schema, target.table) or target.table
    M.error(
      ('the referenced table `%s` is not in the loaded schema - reload it from the tree'):format(
        named
      )
    )
    return
  end
  local origin = ('%s.%s'):format(from.name, cell.name)
  -- The target column can be implicit: sqlite records no `to` for a reference to the primary
  -- key, so the target's own columns have to be loaded before the predicate exists.
  M.load_relation_details(relation, function()
    local column = target.column or lone_primary_key(session.catalog, relation)
    if not column then
      M.error(
        ('`%s` names no target column, and `%s` has no single-column primary key to assume'):format(
          origin,
          relation.name
        )
      )
      return
    end
    local predicate, problem = cell_predicate(session, column, cell.value, '=')
    if not predicate then
      M.error(problem)
      return
    end
    M.open_relation(relation, { filter = predicate, origin = origin })
    if target.composite then
      M.notify(('this foreign key spans several columns; filtered on `%s` only'):format(column))
    end
  end)
end

--- Follow the foreign key on the cell under the cursor to the row it references.
---
--- A read, start to finish: the target comes from metadata already loaded, and the referenced
--- row is browsed through the same paged read path as any other table.
---@param cell dblens.Cell
function M.follow_fk(cell)
  local session = state.session
  if not session then
    M.error('not connected')
    return
  end
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    M.notify('following a foreign key needs a table; open one from the tree')
    return
  end
  local column = column_info(session, source.relation, cell.name)
  local targets = column and fk.targets(column.fk, cell.name) or {}
  if #targets == 0 then
    M.notify(('`%s` has no foreign key to follow'):format(cell.name))
    return
  end
  if cell.value == nil or cell.value == protocol.NULL then
    M.notify(('`%s` is NULL in this row, so it references nothing'):format(cell.name))
    return
  end
  if #targets == 1 then
    open_fk_target(source.relation, cell, targets[1])
    return
  end
  -- A column can carry more than one reference; ask rather than silently take the first.
  local items = {}
  for _, target in ipairs(targets) do
    items[#items + 1] = {
      text = target.table,
      detail = target.column and ('-> ' .. target.column) or 'primary key',
      value = target,
    }
  end
  require('dblens.ui.picker').select(state, {
    title = ('%s references'):format(cell.name),
    items = items,
    on_choose = function(target)
      open_fk_target(source.relation, cell, target)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- in-result search

--- Highlight every cell of the loaded result containing `term`.
---
--- Matching is over the underlying values, so a hit inside a value the grid clipped is found —
--- which the buffer's own `/` cannot do.
---@param term string
---@return dblens.Match?  -- the match now current, for the view to move the cursor to
function M.search_result(term)
  assert(type(term) == 'string', 'app.search_result: expected a term')
  local result = state.grid.result
  if not result or #result.columns == 0 then
    M.notify('there is no result to search')
    return nil
  end
  if vim.trim(term) == '' then
    M.clear_search()
    return nil
  end
  local matches, keys = search_mod.find(result, term)
  if #matches == 0 then
    state.grid.search = nil
    M.render()
    M.notify(('no cell contains `%s`'):format(term))
    return nil
  end
  state.grid.search = { term = term, matches = matches, keys = keys, index = 1 }
  M.render()
  M.notify(('match 1 of %d for `%s`'):format(#matches, term))
  return matches[1]
end

function M.clear_search()
  if not state.grid.search then
    return
  end
  state.grid.search = nil
  M.render()
  M.notify('search cleared')
end

--- Move to the next or previous match, wrapping.
---@param delta integer
---@return dblens.Match?
function M.step_match(delta)
  local search = state.grid.search
  if not search then
    M.notify('nothing has been searched for yet')
    return nil
  end
  search.index = search_mod.step(#search.matches, search.index, delta)
  M.notify(('match %d of %d for `%s`'):format(search.index, #search.matches, search.term))
  return search.matches[search.index]
end

-- ---------------------------------------------------------------------------
-- queries

--- Run SQL from the editor. Multiple statements run in order and stop at the first error.
---@param text string
---@param opts { label: string?, explain: boolean?, analyze: boolean?, new_tab: boolean? }?
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
  if opts.new_tab and not M.open_tab() then
    return
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
---
--- The rows land in the tab the run was started from, whatever tab is on screen when they arrive,
--- and only while that tab has not moved on to something else.
---@param approval dblens.WriteApproval?
function M.execute_statements(statements, original, opts, approval)
  local session = state.session
  local grid = state.grid
  local fetch = new_fetch(grid)
  local source = { kind = 'query', sql = original, label = opts.label or 'query' }
  set_busy('query', nil)
  local job = session:run_script(
    statements,
    { approval = approval },
    live(function(outcomes)
      if grid.fetch ~= fetch then
        return
      end
      set_busy(nil, nil)
      local last = outcomes[#outcomes]
      if last and last.err then
        grid.error = last.err
        grid.source = source
        grid.result = nil
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
      new_epoch(grid)
      if not shown then
        grid.source = source
        grid.result = { columns = {}, rows = {}, malformed = 0 }
        grid.error = nil
        grid.elapsed_ms = total_ms
        grid.message = ('%d statement(s) ran, no rows returned'):format(#outcomes)
        M.render()
        M.refresh_after_write(statements)
        return
      end
      shown.elapsed_ms = total_ms
      present(grid, shown, source)
      M.render()
      M.refresh_after_write(statements)
    end)
  )
  grid.job = job
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
  -- Not one message with the engine's name swapped in: on a best-effort engine the SERVER is not
  -- the one refusing, so saying it does would be the overclaim `LOCKED` already invites.
  local strong = session.adapter.read_only_enforcement.strength == 'strong'
  local locked_message = strong
      and ('`%s` is locked - the server refuses every write'):format(session.spec.name)
    or ('`%s` is locked - dblens refuses the writes it recognises; the server does not '):format(
        session.spec.name
      )
      .. '(:h dblens-safety-mssql)'
  M.notify(
    want and locked_message
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
  return grid_mod.render({
    columns = result.columns,
    rows = result.rows,
    types = state.grid.types,
    max_col_width = ui.grid.max_col_width,
    null_display = ui.grid.null_display,
    separator = ui.grid.separator,
    truncation = ui.grid.truncation,
    sort = state.grid.sort,
    dirty = state.grid.dirty,
    search = state.grid.search and state.grid.search.keys or nil,
  })
end

M.set_busy = set_busy
--- Exported so a UI module that starts its own client call binds the result to this instance too.
M.live = live
return M
