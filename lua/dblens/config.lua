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

  --- Workspace database discovery (`:DbLensDiscover`). `auto` only decides whether opening
  --- dblens with NO connection configured offers what a scan finds; nothing is ever connected
  --- without the user picking it, and nothing is scanned until dblens is opened.
  discovery = { auto = true, max_depth = 6, max_entries = 20000 },

  --- Exporting a whole result or a whole table. `max_rows` is a foot-gun bound, not a render
  --- limit: it becomes the LIMIT of the single statement the export reads with, and reaching it
  --- STOPS the export and says so — it never trims the file in silence.
  export = { max_rows = 1000000 },

  --- `:DbLensFormat`. An EMPTY command detects an installed formatter; set an argv ARRAY to pick
  --- one, e.g. `{ 'sqlfluff', 'format', '--dialect', 'postgres', '-' }`. Never a shell string: it
  --- is spawned directly, gets the SQL on stdin, and only reformats text.
  format = { command = {} },

  --- Importing a CSV into a table (`:DbLensImport`). EDIT mode only. `max_rows` caps the rows one
  --- import may insert, `max_bytes` the file it will read: both refuse loudly rather than
  --- importing part of a file.
  import = { max_rows = 10000, max_bytes = 16 * 1024 * 1024 },

  history = { enabled = true, max_entries = 500 },
  --- Restoring reconnects, so it is opt-in: nothing reaches a database on startup by default.
  session = { restore = false, auto_save = true },
  completion = { enabled = true, keyword_case = 'upper', min_chars = 1 },

  ui = {
    border = 'rounded',
    --- Draw the line between two panes as a plain rule instead of the buffer name. Window-local
    --- to the dblens tab; set false to keep your own statusline there.
    statusline = true,
    --- true = plain Unicode symbols, 'nerd' = Nerd Font glyphs, false = ASCII.
    icons = true,
    winbar = true,
    sidebar = { width = 34, position = 'left' },
    --- Share of the main column given to results; the editor takes the rest. `max_tabs` caps how
    --- many results can be open at once — each tab holds a whole result set.
    results = { height = 0.55, max_tabs = 8 },
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

  --- One entry per adapter kind: the binary each one shells out to. MariaDB ships `mariadb`
  --- rather than `mysql`, and SQL Server's client is `sqlcmd` (Microsoft's or go-sqlcmd).
  clients = {
    sqlite = 'sqlite3',
    postgres = 'psql',
    mysql = 'mysql',
    mariadb = 'mariadb',
    duckdb = 'duckdb',
    mssql = 'sqlcmd',
  },

  --- Per-scope action -> lhs overrides. Defaults and valid action names live in `dblens.keymaps`.
  keymaps = { global = {}, sidebar = {}, results = {}, editor = {} },
}

--- Options whose default is nil because it is derived from `stdpath` at setup time. They are
--- absent from `defaults`, so the unknown-key check needs to know they are real.
local DERIVED = { connections_file = 'string', history_file = 'string', state_file = 'string' }

--- Options that legitimately accept more than one type; `validate` checks their values instead.
local MULTI_TYPE = { ['ui.icons'] = true }

--- Subtrees whose KEYS are user-defined rather than fixed by the schema. The container itself is
--- still type-checked: exempting it too let `connections = "psql"` through `setup{}` and fail
--- much later inside `ipairs`, and `ui.highlights = "nope"` kill setup from inside another module.
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
    -- `false` in place of a keymap scope means "bind nothing here"; `validate_keymaps` owns it.
    local scope_off = value == false and at:match('^keymaps%.[^.]+$') ~= nil
    if want and value ~= nil and not scope_off and type(value) ~= want then
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

---@param value any
---@param at string  -- dotted path, so the message names the option the user wrote
local function positive_int(value, at)
  if type(value) ~= 'number' or value ~= math.floor(value) or value < 1 then
    error(('dblens: option `%s` must be a positive integer'):format(at), 0)
  end
end

local function one_of(value, at, allowed)
  local quoted = {}
  for _, candidate in ipairs(allowed) do
    if value == candidate then
      return
    end
    quoted[#quoted + 1] = ("'%s'"):format(candidate)
  end
  error(('dblens: option `%s` must be one of %s'):format(at, table.concat(quoted, ', ')), 0)
end

--- A fraction of the screen: strictly inside (0, 1), so a float can never be zero-sized or
--- larger than the editor.
local function fraction(value, at)
  if type(value) ~= 'number' or value <= 0 or value >= 1 then
    error(('dblens: option `%s` must be a fraction strictly between 0 and 1'):format(at), 0)
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

--- Border styles `nvim_open_win` accepts by name, which is all `ui.border` takes: the merge type
--- check already refuses anything but a string, so the eight-piece list form is out of scope.
--- Unchecked, a name Neovim does not know opened the main layout fine and then failed the first
--- time any float did — including the destructive-write confirmation.
local BORDERS = { 'none', 'single', 'double', 'rounded', 'solid', 'shadow' }

--- Every numeric option a user can set to a value that only fails much later, deep in a pane.
---
--- The rule these share: a documented tunable must never be able to wedge or blank the UI.
--- `ui.grid.chunk_size = 0` made the render loop reschedule itself with no progress, at 100% CPU,
--- past SIGTERM -- the editor had to be SIGKILLed and every unsaved buffer in it was lost.
local function validate_ui(ui)
  fraction(ui.results.height, 'ui.results.height')
  fraction(ui.float.max_width, 'ui.float.max_width')
  fraction(ui.float.max_height, 'ui.float.max_height')
  positive_int(ui.results.max_tabs, 'ui.results.max_tabs')
  positive_int(ui.sidebar.width, 'ui.sidebar.width')
  positive_int(ui.grid.chunk_size, 'ui.grid.chunk_size')
  positive_int(ui.spinner.interval, 'ui.spinner.interval')
  one_of(ui.sidebar.position, 'ui.sidebar.position', { 'left', 'right' })
  if ui.icons ~= true and ui.icons ~= false and ui.icons ~= 'nerd' then
    error("dblens: option `ui.icons` must be true, false or 'nerd'", 0)
  end
  if ui.grid.max_col_width < 4 then
    error('dblens: option `ui.grid.max_col_width` must be at least 4', 0)
  end
  if type(ui.border) == 'string' then
    one_of(ui.border, 'ui.border', BORDERS)
  end
  if not vim.islist(ui.spinner.frames) or #ui.spinner.frames == 0 then
    error('dblens: option `ui.spinner.frames` must be a non-empty list', 0)
  end
end

--- `format.command` is an argv ARRAY, checked here rather than at spawn time: a shell string
--- would be spawned as one binary with a name full of spaces, and the error would name the
--- formatter instead of the option that is wrong.
local function validate_format(command)
  if not vim.islist(command) then
    error('dblens: option `format.command` must be an argv list, e.g. { `pg_format`, `-` }', 0)
  end
  for index, part in ipairs(command) do
    if type(part) ~= 'string' or part == '' then
      error(('dblens: option `format.command[%d]` must be a non-empty string'):format(index), 0)
    end
  end
end

local function validate(options)
  positive_int(options.page_size, 'page_size')
  positive_int(options.max_rows, 'max_rows')
  positive_int(options.max_bytes, 'max_bytes')
  positive_int(options.timeout_ms, 'timeout_ms')
  positive_int(options.export.max_rows, 'export.max_rows')
  positive_int(options.import.max_rows, 'import.max_rows')
  positive_int(options.import.max_bytes, 'import.max_bytes')
  positive_int(options.history.max_entries, 'history.max_entries')
  positive_int(options.discovery.max_depth, 'discovery.max_depth')
  positive_int(options.discovery.max_entries, 'discovery.max_entries')
  one_of(options.completion.keyword_case, 'completion.keyword_case', { 'upper', 'lower', 'keep' })
  validate_format(options.format.command)
  validate_ui(options.ui)
  validate_keymaps(options.keymaps)
end

--- Resolved options. Replaced wholesale by `setup`; never mutated in place, so a reader of
--- `config.get()` always sees a consistent snapshot.
local current = nil

--- Why the last `setup{}` was rejected, or nil. `get()` falls back to pristine defaults either
--- way, so without this a rejected config and a never-configured one are indistinguishable — and
--- `:checkhealth` reported a green configuration to a user whose own one had just been refused.
local rejected = nil

--- Pristine defaults, resolved once. Kept apart from `current` so that falling back to them
--- never reads as a successful `setup{}`.
local fallback = nil

local function resolve(opts)
  local options = merge(M.defaults, opts, '')
  default_paths(options)
  validate(options)
  return options
end

---@param opts table?
---@return table resolved options
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then
    error('dblens.setup: expected a table', 0)
  end
  local ok, options = pcall(resolve, opts)
  if not ok then
    rejected = tostring(options)
    error(options, 0)
  end
  rejected = nil
  current = options
  return options
end

--- Where the options `get()` returns came from, and whether the last `setup{}` was refused.
--- Both matter: a refused `setup` after a successful one leaves the EARLIER options in force.
---@return 'configured'|'defaults' state, string? rejected  -- why the last setup{} failed
function M.status()
  return current and 'configured' or 'defaults', rejected
end

--- Resolved options, falling back to defaults when `setup` was never called (zero-config works)
--- or when it was refused. The fallback does NOT become the configured state.
---@return table
function M.get()
  if current then
    return current
  end
  if not fallback then
    fallback = resolve({})
  end
  return fallback
end

return M
