--- Workspace database discovery: what the project in front of you appears to have a database in.
---
--- What it does: READ files under the workspace root — database files, `docker-compose*.yml`,
--- `.env` — and turn what they describe into connection candidates.
---
--- What it never does, and these are the security properties of the feature:
---  * it never connects and never executes anything it finds; a candidate is a description until
---    the user picks one, and picking one opens it LOCKED like every other connection;
---  * it never persists anything. `to_spec` builds an ordinary spec WITHOUT the password, so the
---    connections file cannot receive a secret this module read out of a `.env`. A discovered
---    password lives in the candidate, in memory, for as long as the session that used it;
---  * it never reads outside the workspace and never follows a symlink. The walk only descends and
---    skips symlinks (`files.lua`); a path a `.env` NAMES is confined to the root by `finalize`,
---    which drops a candidate resolving above it. The walk is bounded in depth, entries, hits and
---    wall-clock time.
local compose_mod = require('dblens.discovery.compose')
local connections = require('dblens.connections')
local env_mod = require('dblens.discovery.env')
local files_mod = require('dblens.discovery.files')

local M = {}

--- Compose and `.env` files actually read, and the most bytes read from one. The walk finds more
--- than this in a monorepo; reading every one of them is where a scan would start to cost.
local MAX_FILES_READ = 12
local MAX_FILE_BYTES = 256 * 1024

--- Origin -> sort rank. A database file in the tree is the most concrete thing discovery can
--- find, so it is what the picker preselects.
local ORIGIN_RANK = { file = 1, compose = 2, env = 3 }

---@class dblens.RawCandidate
---@field name string
---@field kind string
---@field target table    -- adapter fields only: path, or host/port/user/database/sslmode
---@field secret string?  -- in memory only
---@field origin 'file'|'compose'|'env'
---@field source string   -- workspace-relative file it came from

---@class dblens.Candidate : dblens.RawCandidate
---@field detail string   -- provenance, shown next to the name in the picker

---@class dblens.DiscoveryReport
---@field root string
---@field stats dblens.ScanStats
---@field read integer     -- compose and `.env` files read
---@field skipped integer  -- candidates dropped: invalid, or pointing outside the workspace

--- The workspace root: the git repository the path is in, else the path itself.
---@param start string?  -- defaults to the editor's working directory
---@return string
function M.root(start)
  local from = start or vim.uv.cwd()
  assert(type(from) == 'string' and from ~= '', 'discovery.root: no working directory')
  local marker = vim.fs.find('.git', { path = from, upward = true, limit = 1 })[1]
  if marker then
    return vim.fs.normalize(vim.fs.dirname(marker))
  end
  return vim.fs.normalize(from)
end

---@param path string
---@return string?
local function read_text(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local text = file:read(MAX_FILE_BYTES)
  file:close()
  return text
end

--- The spec a candidate becomes. LOCKED, and without the secret — deliberately.
---
--- This is the one place a candidate turns into something the rest of dblens accepts, so it is
--- the one place that has to be sure the password cannot ride along: whatever holds a spec may
--- eventually write it to the connections file.
---@param candidate dblens.Candidate
---@param name string?  -- override, when the candidate's own name is taken
---@return dblens.ConnectionSpec
function M.to_spec(candidate, name)
  assert(type(candidate) == 'table', 'discovery.to_spec: expected a candidate')
  assert(type(candidate.kind) == 'string', 'discovery.to_spec: candidate has no kind')
  local spec = vim.deepcopy(candidate.target)
  spec.name = name or candidate.name
  spec.kind = candidate.kind
  spec.read_only = true
  spec.source = 'discovered'
  assert(
    spec.password == nil and spec.password_env == nil and spec.password_cmd == nil,
    'discovery.to_spec: a discovered spec must carry no secret and no secret reference'
  )
  return spec
end

--- Where a candidate points, in one short phrase.
---@param candidate dblens.RawCandidate
---@return string
local function target_label(candidate)
  local target = candidate.target
  if target.path then
    return vim.fn.fnamemodify(target.path, ':~')
  end
  return ('%s:%s/%s'):format(target.host or 'localhost', target.port or '?', target.database or '?')
end

--- The line under the name in the picker: engine, where it points, and which file said so.
---@param candidate dblens.RawCandidate
---@return string
local function detail_for(candidate)
  if candidate.origin == 'file' then
    return ('(%s, file)'):format(candidate.kind)
  end
  return ('(%s, %s, from %s)'):format(candidate.kind, target_label(candidate), candidate.source)
end

--- What makes two candidates the same database. Two files cannot collide inside one walk, but a
--- `DATABASE_URL` naming a file the walk already found is the common case.
---@param candidate dblens.RawCandidate
---@return string
local function identity(candidate)
  local target = candidate.target
  if target.path then
    return candidate.kind .. '|' .. target.path
  end
  return ('%s|%s|%s|%s'):format(
    candidate.kind,
    target.host or '',
    target.port or '',
    target.database or ''
  )
end

--- A name no existing connection and no earlier candidate is using.
---@param base string
---@param taken table<string, boolean>
---@return string
local function unique_name(base, taken)
  if not taken[base] then
    taken[base] = true
    return base
  end
  local at = 2
  while taken[('%s (%d)'):format(base, at)] do
    at = at + 1
  end
  local name = ('%s (%d)'):format(base, at)
  taken[name] = true
  return name
end

--- Database files the walk found, as candidates named by their path in the workspace.
---@param found dblens.ScanResult
---@return dblens.RawCandidate[]
local function file_candidates(found)
  local out = {}
  for _, hit in ipairs(found.databases) do
    out[#out + 1] = {
      name = hit.relative,
      kind = hit.kind,
      target = { path = hit.path },
      origin = 'file',
      source = hit.relative,
    }
  end
  return out
end

--- `.env` values keyed by file directory, so a compose file can interpolate the `.env` beside it
--- the way `docker compose` itself does.
---@param texts { hit: dblens.ScanHit, text: string }[]
---@return table<string, table<string, string>>
local function vars_by_directory(texts)
  local out = {}
  for _, entry in ipairs(texts) do
    local dir = vim.fs.dirname(entry.hit.path)
    out[dir] = out[dir] or {}
    for _, pair in ipairs(env_mod.parse(entry.text)) do
      if out[dir][pair.key] == nil then
        out[dir][pair.key] = pair.value
      end
    end
  end
  return out
end

--- Read the first `MAX_FILES_READ` hits of a category.
---@param hits dblens.ScanHit[]
---@return { hit: dblens.ScanHit, text: string }[]
local function read_all(hits)
  local out = {}
  for _, hit in ipairs(hits) do
    if #out >= MAX_FILES_READ then
      return out
    end
    local text = read_text(hit.path)
    if text then
      out[#out + 1] = { hit = hit, text = text }
    end
  end
  return out
end

---@param anchor string  -- normalized, no trailing slash
---@param path string
---@return boolean
local function under(anchor, path)
  return path == anchor or path:sub(1, #anchor + 1) == anchor .. '/'
end

--- Whether a discovered file path stays inside the workspace, before AND after symlink resolution.
---
--- The walk cannot leave the root — it descends and refuses symlinks — but a `sqlite:///../x.db`
--- in a `.env` resolves wherever it likes, which made "never reads above the workspace root" false.
--- Both spellings of the root are anchors because `M.root` normalizes and `files.scan` realpaths;
--- on a system where the root sits under a symlinked prefix only one of them matches.
---@param root string
---@param path string
---@return boolean
local function within_root(root, path)
  local raw = vim.fs.normalize(root)
  local real = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  local resolved = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
  return (under(raw, path) or under(real, path)) and (under(raw, resolved) or under(real, resolved))
end

--- Why a candidate cannot be offered, or nil when it can.
---@param candidate dblens.RawCandidate
---@param name string
---@param root string
---@return string? problem
local function candidate_problem(candidate, name, root)
  -- Validated against the same rules a hand-written connection passes, so a candidate the user
  -- can pick is one dblens can actually open -- and so no discovered value reaches a client argv
  -- as an option.
  local problem = connections.validate(M.to_spec(candidate, name))
  if problem then
    return problem
  end
  if candidate.target.path and not within_root(root, candidate.target.path) then
    return ('`%s` is outside the workspace'):format(candidate.target.path)
  end
  return nil
end

--- Drop duplicates and anything that cannot be offered, and give every survivor a unique name and
--- a provenance line.
---@param raw dblens.RawCandidate[]
---@param taken table<string, boolean>
---@param root string
---@return dblens.Candidate[] candidates, integer skipped
local function finalize(raw, taken, root)
  local out, seen, skipped = {}, {}, 0
  for _, candidate in ipairs(raw) do
    local key = identity(candidate)
    if not seen[key] then
      seen[key] = true
      local name = unique_name(candidate.name, taken)
      if candidate_problem(candidate, name, root) then
        skipped = skipped + 1
        taken[name] = nil
      else
        candidate.name = name
        candidate.detail = detail_for(candidate)
        out[#out + 1] = candidate
      end
    end
  end
  return out, skipped
end

--- Everything the workspace's files describe, best-effort.
---
--- Calls `on_done(candidates, report)` exactly once. Candidates are ordered database files first
--- (the most concrete thing there is), then compose services, then `.env` URLs.
---@param opts { root: string, taken: string[]?, bounds: table? }
---@param on_done fun(candidates: dblens.Candidate[], report: dblens.DiscoveryReport)
---@return dblens.Job
function M.scan(opts, on_done)
  assert(type(opts.root) == 'string' and opts.root ~= '', 'discovery.scan: needs a root')
  assert(type(on_done) == 'function', 'discovery.scan: on_done must be a function')

  local taken = {}
  for _, name in ipairs(opts.taken or {}) do
    taken[name] = true
  end

  return files_mod.scan(opts.root, opts.bounds, function(found, stats)
    local env_texts = read_all(found.env)
    local compose_texts = read_all(found.compose)
    local vars = vars_by_directory(env_texts)

    local raw = file_candidates(found)
    for _, entry in ipairs(compose_texts) do
      local dir = vim.fs.dirname(entry.hit.path)
      vim.list_extend(
        raw,
        compose_mod.parse(entry.text, { source = entry.hit.relative, vars = vars[dir] })
      )
    end
    for _, entry in ipairs(env_texts) do
      vim.list_extend(
        raw,
        env_mod.candidates(entry.text, {
          source = entry.hit.relative,
          dir = vim.fs.dirname(entry.hit.path),
        })
      )
    end
    table.sort(raw, function(a, b)
      if ORIGIN_RANK[a.origin] ~= ORIGIN_RANK[b.origin] then
        return ORIGIN_RANK[a.origin] < ORIGIN_RANK[b.origin]
      end
      return a.name < b.name
    end)

    local candidates, skipped = finalize(raw, taken, opts.root)
    on_done(candidates, {
      root = opts.root,
      stats = stats,
      read = #env_texts + #compose_texts,
      skipped = skipped,
    })
  end)
end

return M
