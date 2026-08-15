--- Importing a CSV file into a table.
---
--- The one write path in dblens whose DATA comes from outside the database, so it is the most
--- guarded thing here. In order:
---  * EDIT mode only. A LOCKED connection is refused before a file is even asked for, and the
---    session gate refuses every statement again on the way out.
---  * the path goes through `dblens.path`, which substitutes `~` and `$VAR` textually and
---    evaluates nothing — no shell ever sees it.
---  * the file is parsed HERE, by `dblens.csv`; nothing is handed to the client to read.
---  * every value becomes a quoted literal through `mutate.insert`. A cell is data, never syntax.
---  * the generated INSERTs are previewed and explicitly confirmed before anything runs.
---  * the run is ONE transaction through the deferred-batch commit, so a row that fails takes the
---    whole import with it and says which row it was. There is no partial import.
local confirm = require('dblens.ui.confirm')
local csv = require('dblens.csv')
local import = require('dblens.import')
local path_mod = require('dblens.path')

local M = {}

local function app()
  return require('dblens.app')
end

--- How many generated statements the preview shows in full.
local SAMPLE = 3

--- Why this connection cannot import right now, or nil.
---@return string?
local function refuse(state)
  local session = state.session
  if not session then
    return 'not connected'
  end
  if session:is_read_only() then
    return ('`%s` is LOCKED, so nothing can be imported into it. Unlock with `:DbLensWrite` '):format(
      session.spec.name
    ) .. '(<leader>dw) first.'
  end
  if session.txn:is_active() then
    -- The import IS a transaction; joining an open one would tie the user's queued changes to it.
    return ('%d change(s) are already queued: commit or roll back before importing'):format(
      session.txn:count()
    )
  end
  return nil
end

--- Read the file the user named, refusing anything a client would misread or that is too big.
---@return string? text, string? error
local function read_file(raw, options)
  local expanded, path_err = path_mod.expand(raw)
  if not expanded then
    return nil, path_err
  end
  local stat = vim.uv.fs_stat(expanded)
  if not stat or stat.type ~= 'file' then
    return nil, ('no such file: %s'):format(expanded)
  end
  if stat.size > options.import.max_bytes then
    return nil,
      ('%s is %.1f MB, past the %.1f MB `import.max_bytes` cap'):format(
        expanded,
        stat.size / 1048576,
        options.import.max_bytes / 1048576
      )
  end
  local file, open_err = io.open(expanded, 'r')
  if not file then
    return nil, ('could not read %s: %s'):format(expanded, tostring(open_err))
  end
  local text = file:read('*a')
  file:close()
  if not text then
    return nil, ('could not read %s'):format(expanded)
  end
  return text, nil
end

--- Parse and plan, with the caps applied and their option named in the message.
---@return dblens.ImportPlan? plan, string? error
local function build_plan(state, relation, text)
  local options = state.options
  local cap = options.import.max_rows
  local rows, parse_err = csv.parse(text, { max_rows = cap + 1 })
  if not rows then
    return nil, ('%s (`import.max_rows` is %d)'):format(parse_err, cap)
  end
  local columns = {}
  for _, column in ipairs(state.session.catalog:info_for(relation).columns or {}) do
    columns[#columns + 1] = column.name
  end
  return import.plan(relation, rows, columns, state.session.adapter.dialect)
end

--- What the user is shown before anything runs.
---@return dblens.ConfirmSection[]
local function preview_sections(plan, source, warn_at)
  local mapping = {}
  for index, column in ipairs(plan.columns) do
    mapping[#mapping + 1] = ('CSV column %d -> %s'):format(index, column)
  end
  local sections = {
    {
      heading = ('%d row(s) into %s'):format(plan.rows, plan.relation.name),
      lines = { source },
      hl = 'DbLensAccent',
    },
    { heading = 'column mapping', lines = mapping, hl = 'DbLensDim' },
  }
  if #plan.unset > 0 then
    sections[#sections + 1] = {
      heading = 'not set by this file (the column default applies)',
      lines = { table.concat(plan.unset, ', ') },
      hl = 'DbLensWarn',
    }
  end
  local sample = {}
  for index = 1, math.min(SAMPLE, #plan.changes) do
    vim.list_extend(sample, confirm.sql_lines(plan.changes[index].sql))
  end
  if plan.rows > SAMPLE then
    sample[#sample + 1] = ('… and %d more'):format(plan.rows - SAMPLE)
  end
  sections[#sections + 1] =
    { heading = 'statements to be run', lines = sample, hl = 'DbLensAccent' }
  if plan.rows >= warn_at then
    sections[#sections + 1] = {
      heading = 'this is a large import',
      lines = { ('%d statements run as ONE transaction; it may take a while'):format(plan.rows) },
      hl = 'DbLensWarn',
    }
  end
  sections[#sections + 1] = {
    heading = 'how it runs',
    lines = { 'one transaction - if any row fails, nothing is imported' },
    hl = 'DbLensDim',
  }
  return sections
end

--- Queue every INSERT through the write gate.
---
--- An INSERT carries no row guard, so `execute_write` queues it without a round trip; the
--- assertion holds that to be true rather than assuming it, because a change that RAN here would
--- be a row imported outside the transaction.
---@return boolean ok, string? error
local function queue_all(session, plan)
  for index, change in ipairs(plan.changes) do
    local queued, problem = nil, nil
    -- `index + 1` is the FILE row: the header is row 1. The label rides into the queue so a
    -- commit-time failure names the same row a queue-time one does.
    local row = ('row %d'):format(index + 1)
    session:execute_write({
      sql = change.sql,
      summary = change.summary,
      destructive = false,
      confirmed = true,
      change = {
        sql = change.sql,
        summary = change.summary,
        relation = plan.relation,
        label = row,
      },
    }, function(outcome, err)
      queued, problem = outcome, err
    end)
    if problem then
      return false, ('%s: %s'):format(row, problem)
    end
    assert(
      queued and queued.queued,
      ('importer: %s was not queued into the transaction'):format(row)
    )
  end
  return true, nil
end

--- Run the planned import as one transaction.
---@param state dblens.State
---@param plan dblens.ImportPlan
local function run(state, plan)
  local session = state.session
  local started, begin_err = session.txn:begin()
  if not started then
    app().error(begin_err)
    return
  end
  local queued, queue_err = queue_all(session, plan)
  if not queued then
    session.txn:reset()
    app().error(('nothing was imported - %s'):format(queue_err))
    return
  end

  app().set_busy('import', nil)
  session:commit(app().live(function(ok, err, queue_kept)
    app().set_busy(nil, nil)
    if not ok then
      -- The server rolled the batch back, so the queue is this session's to drop: leaving the
      -- user with several thousand queued changes they did not ask for would be worse than the
      -- failure itself. `commit` already dropped it when the outcome is unknown.
      if queue_kept then
        session.txn:reset()
      end
      app().error(('nothing was imported - %s'):format(err))
      return
    end
    app().notify(('imported %d row(s) into %s'):format(plan.rows, plan.relation.name))
    app().refresh_grid()
  end))
end

--- Ask for a file, plan the import, and run it once the user confirms.
---@param state dblens.State
---@param relation dblens.Relation
function M.start(state, relation)
  assert(type(relation) == 'table' and relation.name, 'importer.start: needs a table')
  local problem = refuse(state)
  if problem then
    app().error(problem)
    return
  end

  vim.ui.input({
    prompt = ('Import CSV into %s: '):format(relation.name),
    default = vim.fn.getcwd() .. '/',
    completion = 'file',
  }, function(input)
    if not input or vim.trim(input) == '' then
      return
    end
    -- Re-checked: the prompt is modal to the user, not to the plugin — a `:DbLensLock` could have
    -- landed while it was open.
    local late = refuse(state)
    if late then
      app().error(late)
      return
    end
    local text, read_err = read_file(vim.trim(input), state.options)
    if not text then
      app().error(read_err)
      return
    end
    -- Columns first: the mapping is against the table's own columns, not against the file.
    app().load_relation_details(relation, function()
      local plan, plan_err = build_plan(state, relation, text)
      if not plan then
        app().error(('cannot import %s: %s'):format(vim.trim(input), plan_err))
        return
      end
      confirm.ask(state.options, {
        title = 'Import CSV - confirm',
        danger = true,
        sections = preview_sections(plan, vim.trim(input), math.max(2, state.options.page_size)),
      }, function()
        local blocked = refuse(state)
        if blocked then
          app().error(blocked)
          return
        end
        run(state, plan)
      end)
    end)
  end)
end

return M
