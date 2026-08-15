--- The bounded workspace walk: database files, compose files and `.env` files.
---
--- Bounded in four ways at once — depth, entries examined, hits kept, and wall-clock budget — so
--- the scan cannot run away on a home directory or a monorepo, and it walks a few directories per
--- tick with `vim.schedule` between them so the editor stays responsive while it runs.
---
--- It never leaves the workspace: it only ever descends from the root, and a symlink is skipped
--- rather than followed, so no file above the root is opened however the tree is arranged.
local M = {}

M.DEFAULTS = {
  max_depth = 6,
  --- Directory entries examined, hits or not. The stop is reported, never silent.
  max_entries = 20000,
  --- Interesting files kept, per category.
  max_hits = 200,
  --- Directories per tick. Small enough that a slow filesystem cannot stall a keystroke.
  dirs_per_tick = 32,
  budget_ms = 3000,
}

--- Directories that never hold a project's own database and cost the most to walk.
local SKIP_DIRS = {
  ['.git'] = true,
  ['.hg'] = true,
  ['.svn'] = true,
  ['node_modules'] = true,
  ['bower_components'] = true,
  ['vendor'] = true,
  ['target'] = true,
  ['dist'] = true,
  ['build'] = true,
  ['out'] = true,
  ['.next'] = true,
  ['.nuxt'] = true,
  ['.venv'] = true,
  ['venv'] = true,
  ['env'] = true,
  ['__pycache__'] = true,
  ['.mypy_cache'] = true,
  ['.pytest_cache'] = true,
  ['.tox'] = true,
  ['.gradle'] = true,
  ['.terraform'] = true,
  ['.idea'] = true,
  ['.direnv'] = true,
  ['.cache'] = true,
  ['coverage'] = true,
  ['.dart_tool'] = true,
  ['.stack-work'] = true,
  ['Pods'] = true,
}

--- Extension -> kind. `.db` is the ambiguous one: it defaults to sqlite and is settled by the
--- file's magic header when the file has one.
local EXTENSIONS = {
  db = 'sqlite',
  sqlite = 'sqlite',
  sqlite3 = 'sqlite',
  sqlite2 = 'sqlite',
  duckdb = 'duckdb',
  ddb = 'duckdb',
}

local SQLITE_MAGIC = 'SQLite format 3\0'
--- DuckDB writes an 8-byte checksum and then `DUCK`, so its magic starts at byte 9.
local DUCKDB_MAGIC_AT = 9
local HEADER_BYTES = 16

--- `.env.example` and friends hold placeholders, not a database anybody runs.
local ENV_TEMPLATES = { example = true, sample = true, template = true, dist = true }

--- First bytes of a file, or '' when it cannot be read.
---@param path string
---@return string
local function header_of(path)
  local file = io.open(path, 'rb')
  if not file then
    return ''
  end
  local head = file:read(HEADER_BYTES) or ''
  file:close()
  return head
end

--- The database kind a file holds, or nil when it is not a database file at all.
---
--- The magic header wins over the extension: a `.db` written by duckdb is a duckdb database, and
--- opening it with the sqlite client would only produce a confusing error.
---@param path string
---@return string?
function M.kind_for(path)
  assert(type(path) == 'string' and path ~= '', 'discovery.files.kind_for: needs a path')
  local extension = path:match('%.([%w]+)$')
  local by_extension = extension and EXTENSIONS[extension:lower()]
  if not by_extension then
    return nil
  end
  local header = header_of(path)
  if header:sub(1, #SQLITE_MAGIC) == SQLITE_MAGIC then
    return 'sqlite'
  end
  if header:sub(DUCKDB_MAGIC_AT, DUCKDB_MAGIC_AT + 3) == 'DUCK' then
    return 'duckdb'
  end
  return by_extension
end

---@param name string
---@return boolean
local function is_env_file(name)
  if name == '.env' then
    return true
  end
  local suffix = name:match('^%.env%.([%w_%-]+)$')
  return suffix ~= nil and not ENV_TEMPLATES[suffix:lower()]
end

---@param name string
---@return boolean
local function is_compose_file(name)
  return require('dblens.discovery.compose').is_compose_file(name)
end

---@class dblens.ScanHit
---@field path string      -- absolute
---@field relative string  -- workspace-relative, for provenance in the UI
---@field kind string?     -- database files only

---@class dblens.ScanResult
---@field databases dblens.ScanHit[]
---@field compose dblens.ScanHit[]
---@field env dblens.ScanHit[]

---@class dblens.ScanStats
---@field entries integer
---@field directories integer
---@field elapsed_ms integer
---@field truncated boolean   -- a bound stopped the walk before it finished
---@field cancelled boolean
---@field error string?

--- Classify one file and record it if it is one of the three kinds worth reading.
---@param found dblens.ScanResult
---@param limits table
local function record(found, limits, path, relative, name)
  if is_compose_file(name) then
    if #found.compose < limits.max_hits then
      found.compose[#found.compose + 1] = { path = path, relative = relative }
    end
    return
  end
  if is_env_file(name) then
    if #found.env < limits.max_hits then
      found.env[#found.env + 1] = { path = path, relative = relative }
    end
    return
  end
  local kind = M.kind_for(path)
  if kind and #found.databases < limits.max_hits then
    found.databases[#found.databases + 1] = { path = path, relative = relative, kind = kind }
  end
end

--- Walk one directory, queueing the subdirectories worth descending into.
---@return boolean ok  -- false when a bound was hit and the walk must stop
local function visit(dir, found, queue, stats, limits)
  local handle = vim.uv.fs_scandir(dir.path)
  -- An unreadable directory is skipped, not fatal: discovery is best-effort over a tree the user
  -- did not prepare for it, and one permission-denied subdirectory must not lose the rest.
  if not handle then
    return true
  end
  stats.directories = stats.directories + 1
  while true do
    local name, entry_type = vim.uv.fs_scandir_next(handle)
    if not name then
      return true
    end
    stats.entries = stats.entries + 1
    if stats.entries > limits.max_entries then
      stats.truncated = true
      return false
    end
    local path = dir.path .. '/' .. name
    if entry_type == nil then
      local stat = vim.uv.fs_lstat(path)
      entry_type = stat and stat.type or 'unknown'
    end
    local relative = dir.relative == '' and name or (dir.relative .. '/' .. name)
    if entry_type == 'directory' then
      if not SKIP_DIRS[name] and dir.depth + 1 <= limits.max_depth then
        queue[#queue + 1] = { path = path, relative = relative, depth = dir.depth + 1 }
      end
    elseif entry_type == 'file' then
      record(found, limits, path, relative, name)
    end
    -- Anything else (a symlink, a socket, a device) is deliberately left alone: following a
    -- symlink is the one way this walk could read outside the workspace.
  end
end

local function by_relative(a, b)
  return a.relative < b.relative
end

--- Scan the workspace for the files discovery reads.
---
--- Calls `on_done(found, stats)` exactly once, on the main loop. `stats.truncated` says a bound
--- stopped the walk early, so a caller can say "these are the first N" rather than "these are all".
---@param root string  -- absolute workspace root
---@param bounds table?  -- overrides for `M.DEFAULTS`
---@param on_done fun(found: dblens.ScanResult, stats: dblens.ScanStats)
---@return dblens.Job
function M.scan(root, bounds, on_done)
  assert(type(root) == 'string' and root ~= '', 'discovery.files.scan: needs a root')
  assert(type(on_done) == 'function', 'discovery.files.scan: on_done must be a function')
  local limits = vim.tbl_extend('force', M.DEFAULTS, bounds or {})
  assert(limits.max_depth >= 1 and limits.dirs_per_tick >= 1, 'discovery.files.scan: bad bounds')

  local found = { databases = {}, compose = {}, env = {} }
  local stats =
    { entries = 0, directories = 0, elapsed_ms = 0, truncated = false, cancelled = false }
  local started = vim.uv.hrtime()
  local cancelled, done = false, false

  local real_root = vim.uv.fs_realpath(root)
  if not real_root then
    stats.error = ('cannot read the workspace root: %s'):format(root)
    on_done(found, stats)
    return {
      cancel = function() end,
      is_done = function()
        return true
      end,
    }
  end

  local queue, at = { { path = real_root, relative = '', depth = 0 } }, 1

  local function finish()
    done = true
    stats.elapsed_ms = math.floor((vim.uv.hrtime() - started) / 1e6)
    stats.cancelled = cancelled
    table.sort(found.databases, by_relative)
    table.sort(found.compose, by_relative)
    table.sort(found.env, by_relative)
    on_done(found, stats)
  end

  local function step()
    if cancelled then
      finish()
      return
    end
    local processed = 0
    while at <= #queue and processed < limits.dirs_per_tick do
      if not visit(queue[at], found, queue, stats, limits) then
        finish()
        return
      end
      at, processed = at + 1, processed + 1
    end
    if at > #queue then
      finish()
      return
    end
    if (vim.uv.hrtime() - started) / 1e6 > limits.budget_ms then
      stats.truncated = true
      finish()
      return
    end
    vim.schedule(step)
  end

  step()
  return {
    cancel = function()
      cancelled = true
    end,
    is_done = function()
      return done
    end,
  }
end

M.SKIP_DIRS = SKIP_DIRS

return M
