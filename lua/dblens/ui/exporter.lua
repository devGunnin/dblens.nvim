--- The export flow: ask where, confirm an overwrite, stream the rows, and report honestly.
---
--- Two scopes reach here — the result the grid is showing, and a whole table picked in the tree —
--- and both write the FULL row set, not the page on screen. Everything is a read: the rows are
--- fetched by the same paged `session:run` path a browse uses, so the gate, the timeout and the
--- byte cap all still apply and a LOCKED connection stays locked.
local confirm = require('dblens.ui.confirm')
local export = require('dblens.export')
local sqlmod = require('dblens.sql')

local M = {}

local function app()
  return require('dblens.app')
end

--- Column names in catalog order, so even a zero-row export carries its header.
---@return string[]
local function column_names(session, relation)
  local names = {}
  for _, column in ipairs(session.catalog:info_for(relation).columns or {}) do
    names[#names + 1] = column.name
  end
  return names
end

--- A `fetch` for `export.stream` reading one window of a relation through the normal gate.
---
--- The UI closing mid-export is reported as an error rather than dropped, so the stream aborts
--- and removes its temp file instead of leaving one behind with no one left to finish it.
local function relation_fetcher(state, relation, scope)
  local session = state.session
  local columns = column_names(session, relation)
  return function(offset, limit, on_done)
    local statement = session.adapter.sql.page(relation, {
      limit = limit,
      offset = offset,
      order_by = scope.order_by,
      where = scope.where,
    })
    local job = session:run(statement, { columns = columns }, function(result, err)
      if app().state() ~= state then
        on_done(nil, 'dblens was closed while the export was running')
        return
      end
      on_done(result, err)
    end)
    -- Re-registered per page, so `<C-c>` reaches the one running right now.
    if app().state() == state then
      app().set_busy('export', job)
    end
  end
end

--- What the user is told when the file has landed. A cap or a truncation is a WARNING, never a
--- footnote: the whole point of this release is that a short file says so.
local function report(rows, path, warning)
  if warning then
    app().notify(
      ('exported %d row(s) to %s - INCOMPLETE: %s'):format(rows, path, warning),
      vim.log.levels.WARN
    )
    return
  end
  app().notify(('exported %d row(s) to %s'):format(rows, path))
end

--- Stream a whole relation to a file.
---@param state dblens.State
---@param relation dblens.Relation
---@param request { path: string, format: string, where: string?, order_by: table? }
function M.relation(state, relation, request)
  assert(type(request.path) == 'string' and request.path ~= '', 'exporter.relation: needs a path')
  local session = state.session
  if not session then
    app().error('not connected')
    return
  end
  local cap = state.options.export.max_rows
  app().set_busy('export', nil)
  export.stream({
    path = request.path,
    format = request.format,
    max_rows = cap,
    batch = state.options.export.batch_size,
    relation = relation,
    dialect = session.adapter.dialect,
    fetch = relation_fetcher(state, relation, request),
  }, function(summary, err)
    if app().state() == state then
      app().set_busy(nil, nil)
    end
    if not summary then
      app().error(('export failed: %s'):format(err))
      return
    end
    report(
      summary.rows,
      summary.path,
      summary.capped and ('stopped at the %d row `export.max_rows` cap'):format(cap) or nil
    )
  end)
end

--- Export a query result.
---
--- The rows the grid holds are capped at `max_rows`, so writing those would be exactly the silent
--- truncation this replaced. A single READ is re-run to get the whole result instead; anything
--- else must not be run a second time, so its rows are written and the shortfall is stated.
local function query(state, source, request)
  local session = state.session
  local statements = sqlmod.classify_all(source.sql, session.adapter.dialect)
  local rerunnable = #statements == 1 and not statements[1].write

  if not rerunnable then
    local result = state.grid.result
    local warning = state.grid.truncated
        and ('this result was truncated at `max_rows` (%d) and the query is not one that can be '):format(
          state.options.max_rows
        ) .. 're-run safely, so the file holds only what was on screen'
      or nil
    local ok, err = export.write(result, request.path, request.format, { note = warning })
    if not ok then
      app().error(err)
      return
    end
    report(#result.rows, request.path, warning)
    return
  end

  app().set_busy('export', nil)
  local job = session:run(source.sql, {}, function(result, err)
    if app().state() ~= state then
      return
    end
    app().set_busy(nil, nil)
    if err then
      app().error(('export failed: %s'):format(err))
      return
    end
    local warning = result.truncated
        and ('the client hit the %d byte `max_bytes` cap'):format(state.options.max_bytes)
      or nil
    local ok, write_err = export.write(result, request.path, request.format, { note = warning })
    if not ok then
      app().error(write_err)
      return
    end
    report(#result.rows, request.path, warning)
  end)
  app().set_busy('export', job)
end

--- Export whatever the grid is showing, in full.
---@param state dblens.State
---@param request { path: string, format: string }
function M.current(state, request)
  local source = state.grid.source
  if not source then
    app().notify('there is no result to export')
    return
  end
  if source.kind == 'relation' then
    M.relation(state, source.relation, {
      path = request.path,
      format = request.format,
      where = state.grid.filter,
      order_by = state.grid.sort,
    })
    return
  end
  if not state.grid.result or #state.grid.result.columns == 0 then
    app().notify('there is no result to export')
    return
  end
  query(state, source, request)
end

-- ---------------------------------------------------------------------------
-- the prompts

--- Ask for a path, refuse a format we cannot write, and confirm before replacing a file.
---@param default string
---@param on_ready fun(request: { path: string, format: string })
local function ask_path(state, default, on_ready)
  vim.ui.input({ prompt = 'Export to ', default = default, completion = 'file' }, function(path)
    if not path or vim.trim(path) == '' then
      return
    end
    local wanted = vim.trim(path)
    local format, format_err = export.format_for(wanted)
    if not format then
      app().error(format_err)
      return
    end
    -- `vim.fn.expand` would run a backtick in the path through the shell; `dblens.path` only
    -- substitutes `~` and `$VAR` textually, and refuses everything it cannot.
    local expanded, path_err = require('dblens.path').expand(wanted)
    if not expanded then
      app().error(path_err)
      return
    end
    local request = { path = expanded, format = format }
    -- Asked before the writer opens: it puts its temp file beside the target, so a prompt after
    -- that point would be asking about a directory already written to.
    if vim.fn.filereadable(expanded) == 0 then
      on_ready(request)
      return
    end
    confirm.ask(state.options, {
      title = 'Overwrite - confirm',
      danger = true,
      sections = {
        { heading = 'this file already exists', lines = { expanded }, hl = 'DbLensWarn' },
      },
    }, function()
      on_ready(request)
    end)
  end)
end

--- A starting path in the working directory, named after what is being exported.
local function default_path(label, format)
  return ('%s/%s.%s'):format(vim.fn.getcwd(), tostring(label):gsub('%W', '_'), format)
end

--- `X` in the grid: the whole result the grid is showing.
function M.prompt_current(state)
  local source = state.grid.source
  if not source or not state.grid.result or #state.grid.result.columns == 0 then
    app().notify('there is no result to export')
    return
  end
  ask_path(state, default_path(source.label or 'result', 'csv'), function(request)
    M.current(state, request)
  end)
end

--- `X` in the tree: a whole table, unfiltered and unsorted.
---@param relation dblens.Relation
function M.prompt_relation(state, relation)
  if not state.session then
    app().error('not connected')
    return
  end
  ask_path(state, default_path(relation.name, 'csv'), function(request)
    M.relation(state, relation, request)
  end)
end

return M
