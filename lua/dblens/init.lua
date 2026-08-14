--- dblens.nvim public API.
---
--- Zero-config works: the commands are defined by `plugin/dblens.lua` and `setup{}` is only
--- needed to change something. Calling `setup` twice is safe and re-applies everything.
local config = require('dblens.config')
local keymaps = require('dblens.keymaps')

local M = {}

--- Release version. Bumped on tag; see CHANGELOG.md.
M.VERSION = '1.0.0'

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
    write_toggle = function()
      app.set_locked(nil)
    end,
    lock = function()
      app.set_locked(true)
    end,
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

--- Run a global action by name.
---
--- Commands go through here rather than reimplementing what the binding does, so `:DbLensTables`
--- and `<leader>dt` can never drift apart.
---@param name string  an action from `keymaps.specs.global`
function M.action(name)
  M.ensure_setup()
  local handler = global_handlers()[name]
  assert(handler, ('dblens.action: unknown action `%s`'):format(tostring(name)))
  handler()
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
  require('dblens.ui.whichkey').setup(options)
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
  local app = require('dblens.app')
  if app.is_open() then
    app.restore_saved()
    return
  end
  app.open(nil, { restore = true })
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

--- Open the active connection for editing. The sanctioned write path; writes still confirm.
function M.write_mode()
  M.ensure_setup()
  require('dblens.app').set_locked(false)
end

--- Lock the active connection: the server refuses every write again.
function M.lock()
  M.ensure_setup()
  require('dblens.app').set_locked(true)
end

--- Show the binding overlay for the pane the cursor is in, for a user who turned the keymaps off.
function M.help()
  M.ensure_setup()
  local app = require('dblens.app')
  if not app.is_open() then
    app.open()
  end
  local state = app.state()
  if not state then
    return
  end
  local pane = require('dblens.ui.layout').current_pane(state.layout) or 'sidebar'
  require('dblens.ui.help').show(state, pane)
end

--- A segment for the user's own statusline: connection, mode, transaction and running state.
---@return string
function M.statusline()
  local app = require('dblens.app')
  local state = app.state()
  if not state or not state.session then
    return ''
  end
  local parts = { state.session.spec.name, state.session:mode() }
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
