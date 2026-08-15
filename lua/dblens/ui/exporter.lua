--- The export flow: ask where, confirm an overwrite, stream the rows, and report honestly.
---
--- Two scopes reach here — the result the grid is showing, and a whole table picked in the tree —
--- and both write the FULL row set, not the page on screen. Everything is a read, through
--- `session:stream`, so the gate still applies and a LOCKED connection stays locked.
---
--- A table export is ONE statement in ONE client invocation, which is what makes the file a
--- SNAPSHOT. The paged version this replaces re-read the table once per batch, each in its own
--- client process with no ordering tying them together: a row deleted between two batches shifted
--- everything after it up, so the file quietly lost a row it never read and kept one that no
--- longer existed — and still reported "exported N row(s)" with no warning. Postgres could do it
--- with no writer at all, since `synchronize_seqscans` lets two unordered scans start at
--- different points. One statement is one server snapshot, and nothing has to be stitched.
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

--- Primary-key columns, which is what makes a sorted export's order TOTAL.
---
--- Only ever appended to a sort the user asked for: two rows equal on the sort column would
--- otherwise come out in whatever order the plan produced, so the same table exported twice could
--- differ. An unsorted export is left unsorted — one statement is already one snapshot, and
--- ordering a whole table to make it prettier is a cost with nothing to buy.
---@return string[]
local function tiebreak_columns(session, relation)
  local names = {}
  for _, column in ipairs(session.catalog:primary_key(relation)) do
    names[#names + 1] = column.name
  end
  return names
end

--- A `run` for `export.stream`: the whole relation, as ONE statement streamed to the file.
---
--- The cap is the statement's own LIMIT, asking for one row more than may be written. That extra
--- row is how a capped run is told from one that ended because the table did — asked and answered
--- inside the same snapshot, so the answer cannot be about a table that has since changed.
---
--- The UI closing mid-export is reported as an error rather than dropped, so the stream aborts
--- and removes its temp file instead of leaving one behind with no one left to finish it.
local function relation_runner(state, relation, scope, max_rows)
  local session = state.session
  local columns = column_names(session, relation)
  local statement = session.adapter.sql.page(relation, {
    limit = max_rows + 1,
    offset = 0,
    order_by = scope.order_by,
    tiebreak = scope.order_by and tiebreak_columns(session, relation) or nil,
    where = scope.where,
  })
  return function(sink, on_done)
    local job = session:stream(statement, {
      columns = columns,
      on_rows = function(names, rows)
        if app().state() ~= state then
          return 'dblens was closed while the export was running'
        end
        return sink(names, rows)
      end,
    }, function(_, err)
      on_done(err)
    end)
    if app().state() == state then
      app().set_busy('export', job)
    end
  end
end

--- What the user is told when the file has landed. A cap or a truncation is a WARNING, never a
--- footnote: the whole point of this release is that a short file says so.
---
--- The notification is transient and the file is not, so a short file that cannot hold a comment
--- of its own is named alongside the marker written beside it.
local function report(rows, path, warning)
  if not warning then
    app().notify(('exported %d row(s) to %s'):format(rows, path))
    return
  end
  local marked = vim.uv.fs_stat(export.marker_for(path))
      and (' - see %s'):format(vim.fn.fnamemodify(export.marker_for(path), ':t'))
    or ''
  app().notify(
    ('exported %d row(s) to %s - INCOMPLETE: %s%s'):format(rows, path, warning, marked),
    vim.log.levels.WARN
  )
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
    relation = relation,
    dialect = session.adapter.dialect,
    run = relation_runner(state, relation, request, cap),
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
    -- that point would be asking about a directory already written to. EXISTENCE, not
    -- readability: a file the user cannot read is still a file the rename would replace.
    if not vim.uv.fs_stat(expanded) then
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
