--- dblens.nvim public API.
---
--- Zero-config works: the commands are defined by `plugin/dblens.lua` and `setup{}` is only
--- needed to change something. Calling `setup` twice is safe and re-applies everything.
local config = require('dblens.config')
local keymaps = require('dblens.keymaps')

local M = {}

local configured = false

--- Global keymaps currently bound, so a second `setup` can take them back down.
local bound = {}

local function unbind_globals()
  for _, entry in ipairs(bound) do
    pcall(vim.keymap.del, entry.mode, entry.lhs)
  end
  bound = {}
end

--- Actions reachable from anywhere, not just inside a dblens window.
local function global_handlers()
  local app = require('dblens.app')
  local function in_ui(fn)
    return function()
      if not app.is_open() then
        app.open()
      end
      local state = app.state()
      if state then
        fn(state)
      end
    end
  end
  return {
    toggle = function()
      app.toggle()
    end,
    connections = in_ui(function(state)
      require('dblens.ui.picker').connections(state)
    end),
    query = in_ui(function(state)
      require('dblens.ui.layout').focus(state.layout, 'editor')
    end),
    tables = in_ui(function(state)
      require('dblens.ui.picker').tables(state)
    end),
    history = in_ui(function(state)
      require('dblens.ui.picker').history(state)
    end),
    snippets = in_ui(function(state)
      require('dblens.ui.picker').snippets(state)
    end),
    txn_begin = function()
      app.txn_begin()
    end,
    txn_commit = function()
      app.txn_commit()
    end,
    txn_rollback = function()
      app.txn_rollback()
    end,
    txn_pending = in_ui(function(state)
      require('dblens.ui.picker').pending(state)
    end),
  }
end

local function bind_globals(options)
  unbind_globals()
  local handlers = global_handlers()
  for _, entry in ipairs(keymaps.resolve('global', options.keymaps.global)) do
    local handler = handlers[entry.spec.action]
    assert(handler, ('dblens: no handler for global action `%s`'):format(entry.spec.action))
    for _, lhs in ipairs(entry.lhs) do
      vim.keymap.set(
        entry.spec.mode,
        lhs,
        handler,
        { desc = 'dblens: ' .. entry.spec.desc, silent = true }
      )
      bound[#bound + 1] = { mode = entry.spec.mode, lhs = lhs }
    end
  end
end

--- Configure dblens. Optional.
---@param opts table?
---@return table resolved options
function M.setup(opts)
  local options = config.setup(opts)
  require('dblens.ui.highlights').setup(options.ui.highlights)
  bind_globals(options)
  configured = true
  return options
end

--- Apply defaults when the user never called `setup`, so zero-config still gets keymaps.
function M.ensure_setup()
  if configured then
    return
  end
  M.setup({})
end

---@param name string?  connection to open
function M.open(name)
  M.ensure_setup()
  require('dblens.app').open(name ~= '' and name or nil)
end

function M.close()
  require('dblens.app').close()
end

function M.toggle()
  M.ensure_setup()
  require('dblens.app').toggle()
end

function M.is_open()
  return require('dblens.app').is_open()
end

--- Names of every configured connection, for command completion.
---@return string[]
function M.connection_names()
  M.ensure_setup()
  local names = {}
  for _, spec in ipairs(require('dblens.connections').load(config.get())) do
    names[#names + 1] = spec.name
  end
  table.sort(names)
  return names
end

--- Reopen the last connection and table.
function M.restore()
  M.ensure_setup()
  local options = config.get()
  local saved, err = require('dblens.state').load(options)
  if err then
    vim.notify('dblens: ' .. err, vim.log.levels.ERROR)
    return
  end
  if not saved or not saved.connection then
    vim.notify('dblens: no saved session to restore')
    return
  end
  local app = require('dblens.app')
  app.open(saved.connection)
  if not saved.relation then
    return
  end
  -- Reopening the table has to wait until the schema for that connection has loaded.
  local attempts = 0
  local timer = vim.uv.new_timer()
  timer:start(
    120,
    120,
    vim.schedule_wrap(function()
      attempts = attempts + 1
      local state = app.state()
      local session = state and state.session
      if session then
        for _, relation in ipairs(session.catalog:all_relations()) do
          if
            relation.name == saved.relation and (relation.schema or '') == (saved.schema or '')
          then
            timer:stop()
            timer:close()
            app.open_relation(relation)
            return
          end
        end
      end
      if attempts >= 40 then
        timer:stop()
        timer:close()
        vim.notify(('dblens: could not reopen `%s`'):format(saved.relation), vim.log.levels.WARN)
      end
    end)
  )
end

--- Add a connection interactively.
function M.add_connection()
  M.ensure_setup()
  require('dblens.ui.form').add(config.get())
end

---@param name string
function M.remove_connection(name)
  M.ensure_setup()
  require('dblens.ui.form').remove(config.get(), name)
end

--- A segment for the user's own statusline: connection, transaction and running state.
---@return string
function M.statusline()
  local app = require('dblens.app')
  local state = app.state()
  if not state or not state.session then
    return ''
  end
  local parts = { state.session.spec.name }
  if state.session:is_read_only() then
    parts[#parts + 1] = 'read-only'
  end
  local txn = state.session.txn:label()
  if txn then
    parts[#parts + 1] = txn
  end
  if state.busy then
    parts[#parts + 1] = state.busy .. '…'
  end
  return table.concat(parts, ' · ')
end

M.health = function()
  require('dblens.health').check()
end

return M
