--- User configuration: defaults, validating merge, and the resolved options singleton.
---
--- The merge rejects unknown keys. A silently ignored typo in `setup{}` is a hidden failure,
--- and the defaults below are the complete shape, so anything else is a mistake worth naming.
local M = {}

M.defaults = {
  --- Connections declared in `setup{}`. Read-only; the picker cannot edit these.
  connections = {},
  --- Files. nil means "derive from stdpath" at setup time.
  connections_file = nil,
  history_file = nil,
  state_file = nil,

  --- Rows fetched per page when browsing a table.
  page_size = 100,
  --- Hard cap on rows rendered from an ad-hoc query. The result is truncated, never the SQL.
  max_rows = 2000,
  --- Hard cap on bytes read from a client process before it is killed.
  max_bytes = 16 * 1024 * 1024,
  timeout_ms = 30000,

  safety = {
    --- Gate UPDATE/DELETE/DROP/TRUNCATE/ALTER behind a preview and an explicit confirmation.
    confirm_destructive = true,
    --- Also gate non-destructive writes (INSERT/CREATE/...).
    confirm_write = false,
    --- Applied to connections that do not set `read_only` themselves. Locked by default: a
    --- connection you have not thought about should not be one you can write to by accident.
    read_only_default = true,
  },

  history = { enabled = true, max_entries = 500 },
  --- Restoring reconnects, so it is opt-in: nothing reaches a database on startup by default.
  session = { restore = false, auto_save = true },
  completion = { enabled = true, keyword_case = 'upper', min_chars = 1 },

  ui = {
    border = 'rounded',
    --- true = plain Unicode symbols, 'nerd' = Nerd Font glyphs, false = ASCII.
    icons = true,
    winbar = true,
    sidebar = { width = 34, position = 'left' },
    --- Share of the main column given to results; the editor takes the rest.
    results = { height = 0.55 },
    grid = {
      max_col_width = 40,
      null_display = 'NULL',
      separator = '│',
      truncation = '…',
      --- Rows highlighted per tick, so a wide result never blocks the UI in one redraw.
      chunk_size = 200,
    },
    float = { max_width = 0.8, max_height = 0.8 },
    spinner = {
      frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
      interval = 80,
    },
    --- Overrides merged over the derived highlight groups, e.g. { DbLensNull = { fg = '#666' } }.
    highlights = {},
  },

  clients = { sqlite = 'sqlite3', postgres = 'psql', mysql = 'mysql' },

  --- Per-scope action -> lhs overrides. Defaults and valid action names live in `dblens.keymaps`.
  keymaps = { global = {}, sidebar = {}, results = {}, editor = {} },
}

--- Options whose default is nil because it is derived from `stdpath` at setup time. They are
--- absent from `defaults`, so the unknown-key check needs to know they are real.
local DERIVED = { connections_file = 'string', history_file = 'string', state_file = 'string' }

--- Options that legitimately accept more than one type; `validate` checks their values instead.
local MULTI_TYPE = { ['ui.icons'] = true }

--- Subtrees whose keys are user-defined rather than fixed by the schema.
local OPEN_PATHS = {
  ['connections'] = true,
  ['ui.highlights'] = true,
  ['keymaps.global'] = true,
  ['keymaps.sidebar'] = true,
  ['keymaps.results'] = true,
  ['keymaps.editor'] = true,
}

local function is_plain_table(v)
  return type(v) == 'table' and not vim.islist(v)
end

local function join(path, key)
  return path == '' and key or (path .. '.' .. key)
end

--- Merge `user` over `base`, rejecting unknown keys and type changes.
--- Errors carry the full dotted path so a typo names itself.
local function merge(base, user, path)
  local out = vim.deepcopy(base)
  for key, value in pairs(user) do
    local at = join(path, key)
    local default = base[key]
    local derived = path == '' and DERIVED[key] or nil
    if default == nil and not derived and not OPEN_PATHS[path] then
      error(('dblens: unknown option `%s`'):format(at), 0)
    end
    local want = derived or (default ~= nil and type(default) or nil)
    if MULTI_TYPE[at] then
      want = nil
    end
    if want and value ~= nil and not OPEN_PATHS[at] and type(value) ~= want then
      error(('dblens: option `%s` expects %s, got %s'):format(at, want, type(value)), 0)
    end
    if is_plain_table(default) and is_plain_table(value) and not OPEN_PATHS[at] then
      out[key] = merge(default, value, at)
    else
      out[key] = value
    end
  end
  return out
end

local function positive_int(options, key)
  local value = options[key]
  if type(value) ~= 'number' or value ~= math.floor(value) or value < 1 then
    error(('dblens: option `%s` must be a positive integer'):format(key), 0)
  end
end

local function default_paths(options)
  local data = vim.fn.stdpath('data') .. '/dblens'
  options.connections_file = options.connections_file or (data .. '/connections.json')
  options.history_file = options.history_file or (data .. '/history.json')
  options.state_file = options.state_file or (data .. '/session.json')
end

--- A keymap scope is a table of action -> lhs overrides, or `false` to bind nothing in it.
---
--- `OPEN_PATHS` exempts these subtrees from the generic type check, so without this a
--- `keymaps.global = false` passed validation and was then silently coerced back to the full
--- default set, and `keymaps.results = 'x'` only failed much later inside a pane.
local function validate_keymaps(keymaps)
  for scope, overrides in pairs(keymaps) do
    if overrides ~= false and type(overrides) ~= 'table' then
      error(
        ('dblens: option `keymaps.%s` expects a table or false, got %s'):format(
          scope,
          type(overrides)
        ),
        0
      )
    end
    for action, lhs in pairs(type(overrides) == 'table' and overrides or {}) do
      local shape = type(lhs)
      if lhs ~= false and shape ~= 'string' and shape ~= 'table' then
        error(
          ('dblens: option `keymaps.%s.%s` expects a key, a list of keys or false, got %s'):format(
            scope,
            action,
            shape
          ),
          0
        )
      end
    end
    -- Names the unknown action now rather than when the pane it belongs to is first opened.
    require('dblens.keymaps').resolve(scope, overrides)
  end
end

local function validate(options)
  positive_int(options, 'page_size')
  positive_int(options, 'max_rows')
  positive_int(options, 'max_bytes')
  positive_int(options, 'timeout_ms')
  local height = options.ui.results.height
  if type(height) ~= 'number' or height <= 0 or height >= 1 then
    error('dblens: option `ui.results.height` must be a fraction strictly between 0 and 1', 0)
  end
  if options.ui.sidebar.position ~= 'left' and options.ui.sidebar.position ~= 'right' then
    error("dblens: option `ui.sidebar.position` must be 'left' or 'right'", 0)
  end
  local icons = options.ui.icons
  if icons ~= true and icons ~= false and icons ~= 'nerd' then
    error("dblens: option `ui.icons` must be true, false or 'nerd'", 0)
  end
  if options.ui.grid.max_col_width < 4 then
    error('dblens: option `ui.grid.max_col_width` must be at least 4', 0)
  end
  validate_keymaps(options.keymaps)
end

--- Resolved options. Replaced wholesale by `setup`; never mutated in place, so a reader of
--- `config.get()` always sees a consistent snapshot.
local current = nil

---@param opts table?
---@return table resolved options
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then
    error('dblens.setup: expected a table', 0)
  end
  local options = merge(M.defaults, opts, '')
  default_paths(options)
  validate(options)
  current = options
  return options
end

--- Resolved options, falling back to defaults when `setup` was never called (zero-config works).
---@return table
function M.get()
  if not current then
    return M.setup({})
  end
  return current
end

return M
