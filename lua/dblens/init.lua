--- dblens.nvim public API.
---
--- Zero-config works: the commands are defined by `plugin/dblens.lua` and `setup{}` is only
--- needed to change something. Calling `setup` twice is safe and re-applies everything.
local config = require('dblens.config')
local keymaps = require('dblens.keymaps')

local M = {}

--- Release version. Bumped on tag; see CHANGELOG.md.
M.VERSION = '1.4.0'

local configured = false

--- Global keymaps currently bound, so a second `setup` can take them back down.
local bound = {}

--- Keys that already answered to something else when dblens bound them. `:checkhealth` reports
--- these; nothing else does, and `vim.keymap.set` would not have said a word.
local taken_over = {}

--- Defined below; both binding paths need it.
local existing_binding

--- Drop the keys the previous `setup{}` bound — but only the ones still answering to dblens. A
--- key another plugin has taken back since is theirs, and deleting it would leave it unbound.
local function unbind_globals()
  for _, entry in ipairs(bound) do
    if not existing_binding(entry.mode, entry.lhs) then
      pcall(vim.keymap.del, entry.mode, entry.lhs)
    end
  end
  bound = {}
end

--- The literal keys an lhs becomes once `<leader>` and the terminal codes are resolved, which is
--- the form `nvim_get_keymap` reports.
local function resolved_keys(lhs)
  local leader = tostring(vim.g.mapleader or '\\')
  local local_leader = tostring(vim.g.maplocalleader or '\\')
  local text = lhs:gsub('<[lL]eader>', function()
    return leader
  end)
  text = text:gsub('<[lL]ocal[lL]eader>', function()
    return local_leader
  end)
  return vim.api.nvim_replace_termcodes(text, true, true, true)
end

--- What `lhs` already answers to in `mode`, or nil. dblens's own binding does not count: a second
--- `setup{}` re-binds what the first one bound.
---@return string?  -- a short description of the existing binding
function existing_binding(mode, lhs)
  local wanted = resolved_keys(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if map.lhs == wanted then
      local desc = map.desc or ''
      if desc:sub(1, 8) == 'dblens: ' then
        return nil
      end
      return desc ~= '' and desc or (map.rhs or 'a Lua callback')
    end
  end
  return nil
end

--- Keys dblens took over from another plugin, newest binding pass only.
---@return { lhs: string, previous: string }[]
function M.keymaps_taken_over()
  return vim.deepcopy(taken_over)
end

--- Actions reachable from anywhere, not just inside a dblens window.
---
--- Every handler requires `dblens.app` when it RUNS, not when it is built. Binding is what
--- happens on every Neovim start, and requiring the app there pulled in the whole query engine —
--- 23 modules, the six adapters and the 1100-line lexer — for a user who never opens dblens.
local function global_handlers()
  local function app()
    return require('dblens.app')
  end
  local function in_ui(fn)
    return function()
      if not app().is_open() then
        app().open()
      end
      local state = app().state()
      if state then
        fn(state)
      end
    end
  end
  return {
    toggle = function()
      app().toggle()
    end,
    connections = in_ui(function(state)
      require('dblens.ui.manager').open(state)
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
      app().set_locked(nil)
    end,
    lock = function()
      app().set_locked(true)
    end,
    txn_begin = function()
      app().txn_begin()
    end,
    txn_commit = function()
      app().txn_commit()
    end,
    txn_rollback = function()
      app().txn_rollback()
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
  taken_over = {}
  local handlers = global_handlers()
  for _, entry in ipairs(keymaps.resolve('global', options.keymaps.global)) do
    local handler = handlers[entry.spec.action]
    assert(handler, ('dblens: no handler for global action `%s`'):format(entry.spec.action))
    local modes = type(entry.spec.mode) == 'table' and entry.spec.mode or { entry.spec.mode }
    for _, lhs in ipairs(entry.lhs) do
      for _, mode in ipairs(modes) do
        local previous = existing_binding(mode, lhs)
        if previous then
          taken_over[#taken_over + 1] = { lhs = lhs, previous = previous }
        end
      end
      vim.keymap.set(modes, lhs, handler, { desc = 'dblens: ' .. entry.spec.desc, silent = true })
      for _, mode in ipairs(modes) do
        bound[#bound + 1] = { mode = mode, lhs = lhs }
      end
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

--- Close dblens for good: end the session, drop the buffers, release everything.
---
--- `hide` is the everyday one — `q` and the toggle use it, and what they leave behind comes back
--- exactly as it was.
function M.close()
  require('dblens.app').close()
end

--- Take dblens off screen, keeping the connection, the result tabs and the SQL buffer.
function M.hide()
  require('dblens.app').hide()
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

--- Scan the workspace for databases and offer what it finds. On-demand only: nothing is scanned
--- until this is called, and nothing connects until the user picks a candidate.
function M.discover()
  M.ensure_setup()
  require('dblens.app').discover()
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

--- Lock the active connection: the server refuses every write again -- on mssql, where there is no
--- such server switch, dblens refuses the writes it recognises instead (`:h dblens-safety-mssql`).
function M.lock()
  M.ensure_setup()
  require('dblens.app').set_locked(true)
end

--- Import a CSV file into a table: the one the grid is browsing, or one picked from the list.
---
--- EDIT mode only, previewed and confirmed, and run as a single transaction — see
--- `dblens.ui.importer` for what each of those means.
function M.import()
  M.ensure_setup()
  local app = require('dblens.app')
  if not app.is_open() then
    app.open()
  end
  local state = app.state()
  if not state then
    return
  end
  local source = state.grid.source
  if source and source.kind == 'relation' then
    require('dblens.ui.importer').start(state, source.relation)
    return
  end
  require('dblens.ui.picker').tables(state, function(relation)
    require('dblens.ui.importer').start(state, relation)
  end)
end

--- Format the SQL editor buffer, or the given line range of it, through the detected formatter.
---
--- Does not open dblens: there is no editor buffer to format until it is open, and opening one to
--- format an empty scratch buffer would be a surprise.
---@param from integer?  -- 1-based; the whole buffer when omitted
---@param to integer?
function M.format(from, to)
  M.ensure_setup()
  local app = require('dblens.app')
  local state = app.state()
  if not state or not app.is_open() then
    app.error('dblens is not open, so there is no SQL buffer to format')
    return
  end
  -- Both ends clamped: `:DbLensFormat` comes pre-clamped from vim, a direct Lua call does not,
  -- and `format_range` asserts its range is inside the buffer rather than reporting it.
  local last = vim.api.nvim_buf_line_count(state.layout.bufs.editor)
  local first = math.min(math.max(from or 1, 1), last)
  require('dblens.ui.editor').format_range(
    state,
    first,
    math.min(math.max(to or last, first), last)
  )
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
