--- Workspace discovery: the bounded walk, the three parsers, and the two properties that make the
--- feature safe — a discovered connection opens LOCKED, and a password it found is never written
--- to the connections file.
local compose = require('dblens.discovery.compose')
local connections = require('dblens.connections')
local discovery = require('dblens.discovery')
local env = require('dblens.discovery.env')
local files = require('dblens.discovery.files')
local h = require('helpers')
local url = require('dblens.discovery.url')

local eq = h.eq

--- The first bytes each engine writes, which is what tells a `.db` written by one from the other.
local SQLITE_HEADER = 'SQLite format 3\0'
local DUCKDB_HEADER = string.rep('\0', 8) .. 'DUCK'

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local file = assert(io.open(path, 'wb'), 'cannot write ' .. path)
  file:write(text)
  file:close()
  return path
end

local COMPOSE = [[
version: '3.8'
services:
  app:
    image: node:20
    ports:
      - "3000:3000"
  db:
    image: postgres:16-alpine
    ports:
      - "5433:5432"
    environment:
      POSTGRES_USER: shop
      POSTGRES_PASSWORD: hunter2
      POSTGRES_DB: shopdb
  metrics:
    image: mysql:8.4
    ports:
      - "127.0.0.1:3307:3306"
    environment:
      - MYSQL_DATABASE=metrics
      - MYSQL_USER=report
      - MYSQL_PASSWORD=reportpw
  cache:
    image: redis:7
    ports:
      - "6379:6379"
  internal:
    image: postgres:16
    expose:
      - "5432"
]]

local DOTENV = [[
# a comment
export DATABASE_URL=postgres://app:s3cr3t@localhost:5432/appdb
REDIS_URL=redis://localhost:6379
ANALYTICS_URL="duckdb:///srv/warehouse.duckdb"
PGDATABASE=grouped
PGHOST=pg.internal
PGPORT=6432
PGPASSWORD=grouppw
]]

--- A workspace with every shape the walk has to get right.
---@return string root
local function fixture_workspace()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/.git', 'p')
  -- Dev databases are normally gitignored, which is exactly why the walk cannot use git.
  write(root .. '/.gitignore', '*.sqlite3\n*.db\n')
  write(root .. '/db/dev.sqlite3', SQLITE_HEADER .. string.rep('\0', 64))
  write(root .. '/data/ambiguous.db', DUCKDB_HEADER .. string.rep('\0', 64))
  write(root .. '/data/plain.db', 'not a database yet')
  write(root .. '/node_modules/pkg/bundled.sqlite3', SQLITE_HEADER)
  write(root .. '/.git/objects/packed.sqlite3', SQLITE_HEADER)
  write(root .. '/a/b/c/d/e/f/g/too-deep.sqlite3', SQLITE_HEADER)
  write(root .. '/docker-compose.yml', COMPOSE)
  write(root .. '/.env', DOTENV)
  write(root .. '/.env.example', 'DATABASE_URL=postgres://user:pass@localhost:5432/example\n')
  return root
end

--- Run a scan to completion and return what it found.
---@return dblens.Candidate[] candidates, dblens.DiscoveryReport report
local function scan(root, bounds)
  local box = h.capture()
  discovery.scan({ root = root, bounds = bounds }, box.sink)
  vim.wait(5000, function()
    return box.called
  end)
  assert(box.called, 'discovery.scan never called back')
  return box[1], box[2]
end

---@return dblens.Candidate?
local function by_name(candidates, name)
  for _, candidate in ipairs(candidates) do
    if candidate.name == name then
      return candidate
    end
  end
  return nil
end

describe('discovery: the workspace walk', function()
  it('finds a gitignored database file, and names it by its path in the project', function()
    local candidates = scan(fixture_workspace())
    local found = by_name(candidates, 'db/dev.sqlite3')
    eq(found ~= nil, true, { fail_reason = 'the gitignored dev database was not found' })
    eq(found.kind, 'sqlite')
    eq(found.origin, 'file')
    eq(found.detail, '(sqlite, file)')
  end)

  it('classifies an ambiguous `.db` by its magic header, not its extension', function()
    local root = fixture_workspace()
    local candidates = scan(root)
    eq(by_name(candidates, 'data/ambiguous.db').kind, 'duckdb')
    -- No header to go on: `.db` defaults to sqlite, which is what it usually is.
    eq(by_name(candidates, 'data/plain.db').kind, 'sqlite')
    eq(files.kind_for(root .. '/db/dev.sqlite3'), 'sqlite')
    eq(files.kind_for(root .. '/docker-compose.yml'), nil)
  end)

  it('skips heavy directories and the git directory', function()
    local candidates = scan(fixture_workspace())
    eq(by_name(candidates, 'node_modules/pkg/bundled.sqlite3'), nil)
    eq(by_name(candidates, '.git/objects/packed.sqlite3'), nil)
  end)

  it('honours the depth bound', function()
    local root = fixture_workspace()
    eq(by_name(scan(root), 'a/b/c/d/e/f/g/too-deep.sqlite3'), nil)
    local shallow = scan(root, { max_depth = 1 })
    eq(by_name(shallow, 'db/dev.sqlite3') ~= nil, true)
    eq(by_name(shallow, 'a/b/c/d/e/f/g/too-deep.sqlite3'), nil)
  end)

  it('stops at the entry cap and says so', function()
    local _, report = scan(fixture_workspace(), { max_entries = 3 })
    eq(report.stats.truncated, true)
    eq(report.stats.entries <= 4, true, { fail_reason = 'the cap did not stop the walk' })
  end)

  it('does not follow a symlink out of the workspace', function()
    local outside = vim.fn.tempname()
    write(outside .. '/secret/elsewhere.sqlite3', SQLITE_HEADER)
    local root = fixture_workspace()
    assert(vim.uv.fs_symlink(outside .. '/secret', root .. '/linked', { dir = true }))
    assert(vim.uv.fs_symlink(outside .. '/secret/elsewhere.sqlite3', root .. '/link.sqlite3'))

    local candidates = scan(root)
    for _, candidate in ipairs(candidates) do
      eq(candidate.name:find('link', 1, true), nil, {
        fail_reason = ('the walk followed a symlink: %s'):format(candidate.name),
      })
    end
  end)

  it('reports the root it scanned and finds every source in one pass', function()
    local root = fixture_workspace()
    local candidates, report = scan(root)
    eq(report.root, root)
    eq(report.read, 2, { fail_reason = 'the compose file and the .env should both be read' })
    local origins = {}
    for _, candidate in ipairs(candidates) do
      origins[candidate.origin] = true
    end
    eq(origins, { file = true, compose = true, env = true })
    -- Files first, so the picker preselects the most concrete candidate.
    eq(candidates[1].origin, 'file')
  end)

  it('ignores a `.env.example`, which holds placeholders rather than a database', function()
    local candidates = scan(fixture_workspace())
    for _, candidate in ipairs(candidates) do
      eq(candidate.source ~= '.env.example', true, {
        fail_reason = 'a template .env produced a candidate',
      })
    end
  end)
end)

describe('discovery: docker-compose', function()
  local function parsed()
    return compose.parse(COMPOSE, { source = 'docker-compose.yml' })
  end

  it('turns database services into candidates with the published host port', function()
    local services = parsed()
    eq(#services, 2, { fail_reason = 'only postgres and mysql are databases dblens can reach' })

    local postgres = services[1]
    eq(postgres.name, 'db')
    eq(postgres.kind, 'postgres')
    eq(postgres.target.host, 'localhost')
    eq(postgres.target.port, 5433)
    eq(postgres.target.user, 'shop')
    eq(postgres.target.database, 'shopdb')
    eq(postgres.secret, 'hunter2')

    local mysql = services[2]
    eq(mysql.kind, 'mysql')
    eq(mysql.target.port, 3307)
    eq(mysql.target.database, 'metrics')
    eq(mysql.target.user, 'report')
    eq(mysql.secret, 'reportpw')
  end)

  it('skips a service that publishes no host port, and one that is not a database', function()
    local names = {}
    for _, service in ipairs(parsed()) do
      names[service.name] = true
    end
    eq(names.internal, nil)
    eq(names.cache, nil)
    eq(names.app, nil)
  end)

  it('applies the image defaults when the environment leaves them out', function()
    local services = compose.parse(
      'services:\n  db:\n    image: postgres:16\n    ports:\n      - 5432:5432\n',
      { source = 'compose.yaml' }
    )
    eq(#services, 1)
    eq(services[1].target.user, 'postgres')
    eq(services[1].target.database, 'postgres')
    eq(services[1].secret, nil)
  end)

  it('resolves ${VAR} from the .env beside it, and drops a value it cannot resolve', function()
    local text = table.concat({
      'services:',
      '  db:',
      '    image: mariadb:11',
      '    ports:',
      '      - "${DB_PORT}:3306"',
      '    environment:',
      '      MARIADB_DATABASE: ${DB_NAME:-fallback}',
      '      MARIADB_ROOT_PASSWORD: ${NOT_SET_ANYWHERE}',
      '',
    }, '\n')
    local services = compose.parse(text, { source = 'compose.yml', vars = { DB_PORT = '3399' } })
    eq(#services, 1)
    eq(services[1].kind, 'mariadb')
    eq(services[1].target.port, 3399)
    eq(services[1].target.database, 'fallback')
    -- A literal `${NOT_SET_ANYWHERE}` is not a password, so the candidate carries none.
    eq(services[1].secret, nil)
  end)

  it('reads the long port form, and knows which files are compose files', function()
    local text = 'services:\n  db:\n    image: postgres\n    ports:\n'
      .. '      - target: 5432\n        published: 5445\n        protocol: tcp\n'
    eq(compose.parse(text, { source = 'x.yml' })[1].target.port, 5445)
    eq(compose.is_compose_file('docker-compose.override.yml'), true)
    eq(compose.is_compose_file('compose.yaml'), true)
    eq(compose.is_compose_file('kubernetes.yml'), false)
  end)
end)

describe('discovery: connection URLs', function()
  it('parses a postgres URL with a password, a port and a query', function()
    local target = url.parse('postgres://app:s3cr3t@db.internal:6543/shop?sslmode=require')
    eq(target.kind, 'postgres')
    eq(target.host, 'db.internal')
    eq(target.port, 6543)
    eq(target.user, 'app')
    eq(target.database, 'shop')
    eq(target.sslmode, 'require')
    eq(target.secret, 's3cr3t')
  end)

  it('fills in the default port, and has no password when the URL carries none', function()
    local target = url.parse('postgresql://localhost/appdb')
    eq(target.port, 5432)
    eq(target.user, nil)
    eq(target.secret, nil)
    eq(url.parse('mysql://root@127.0.0.1/metrics').port, 3306)
    eq(url.parse('mysql://root@127.0.0.1:3307/metrics').port, 3307)
    eq(url.parse('mariadb://wiki@db/wiki').kind, 'mariadb')
  end)

  it('parses the file-backed schemes into a path', function()
    eq(url.parse('sqlite:///srv/app/dev.sqlite3').path, '/srv/app/dev.sqlite3')
    eq(url.parse('sqlite:///srv/app/dev.sqlite3').kind, 'sqlite')
    eq(url.parse('sqlite://./db/dev.sqlite3').path, './db/dev.sqlite3')
    eq(url.parse('sqlite:relative.db').path, 'relative.db')
    eq(url.parse('duckdb:///data/warehouse.duckdb').kind, 'duckdb')
    -- An in-memory database is not a file anything can open.
    eq(url.parse('sqlite://:memory:'), nil)
  end)

  it('percent-decodes the user info, so an awkward password survives', function()
    local target = url.parse('postgres://us%20er:p%40ss%2Fword@host/db')
    eq(target.user, 'us er')
    eq(target.secret, 'p@ss/word')
  end)

  it('is not fooled by a URL that is not a database', function()
    eq(url.parse('redis://localhost:6379'), nil)
    eq(url.parse('https://example.com/db'), nil)
    eq(url.parse('jdbc:postgresql://host/db'), nil)
    eq(url.parse('not a url'), nil)
  end)
end)

describe('discovery: .env files', function()
  it('reads exported, quoted and commented pairs', function()
    local pairs_list = env.parse(DOTENV)
    local map = {}
    for _, entry in ipairs(pairs_list) do
      map[entry.key] = entry.value
    end
    eq(map.DATABASE_URL, 'postgres://app:s3cr3t@localhost:5432/appdb')
    eq(map.ANALYTICS_URL, 'duckdb:///srv/warehouse.duckdb')
    eq(map.PGPORT, '6432')
    eq(#pairs_list, 7, { fail_reason = 'the comment line is not a variable' })
  end)

  it('makes a candidate of every value that is a database URL, named after the variable', function()
    local candidates = env.candidates(DOTENV, { source = '.env', dir = '/srv/app' })
    local names = {}
    for _, candidate in ipairs(candidates) do
      names[candidate.name] = candidate
    end
    eq(names.DATABASE_URL.kind, 'postgres')
    eq(names.DATABASE_URL.target.database, 'appdb')
    eq(names.DATABASE_URL.secret, 's3cr3t')
    eq(names.REDIS_URL, nil)
    eq(names.ANALYTICS_URL.kind, 'duckdb')
    eq(names.ANALYTICS_URL.target.path, '/srv/warehouse.duckdb')
  end)

  it('resolves a file URL against the project when that is the file that exists', function()
    local project = vim.fn.tempname()
    write(project .. '/db/dev.sqlite3', SQLITE_HEADER)
    local text = 'DATABASE_URL=sqlite:///db/dev.sqlite3\n'
    eq(
      env.candidates(text, { source = '.env', dir = project })[1].target.path,
      project .. '/db/dev.sqlite3'
    )
    -- Nothing to go on: the path stays as the URL wrote it.
    eq(
      env.candidates(text, { source = '.env', dir = '/nowhere' })[1].target.path,
      '/db/dev.sqlite3'
    )
  end)

  it('reads a PG* variable group as a connection', function()
    local candidates = env.candidates(DOTENV, { source = '.env', dir = '/srv/app' })
    local grouped = nil
    for _, candidate in ipairs(candidates) do
      if candidate.name == 'grouped' then
        grouped = candidate
      end
    end
    eq(grouped ~= nil, true, { fail_reason = 'the PG* group produced no candidate' })
    eq(grouped.kind, 'postgres')
    eq(grouped.target.host, 'pg.internal')
    eq(grouped.target.port, 6432)
    eq(grouped.secret, 'grouppw')
  end)

  it('needs a database to be named before a variable group is a connection', function()
    eq(#env.candidates('PGHOST=db\nPGPASSWORD=x\n', { source = '.env', dir = '/srv' }), 0)
  end)
end)

describe('discovery: what a candidate becomes', function()
  local function url_candidate()
    local candidates =
      env.candidates(DOTENV, { source = '.env', dir = vim.fn.tempname() .. '/app' })
    return by_name(candidates, 'DATABASE_URL')
  end

  it('is a LOCKED connection, whatever it was discovered from', function()
    local spec = discovery.to_spec(url_candidate())
    eq(spec.read_only, true)
    eq(spec.source, 'discovered')
    eq(connections.validate(spec), nil)

    local session = require('dblens.session').new(spec, require('dblens.config').get())
    eq(session:is_read_only(), true)
    eq(session:mode(), 'LOCKED')
  end)

  it('carries no password and no password reference into the spec', function()
    local candidate = url_candidate()
    eq(candidate.secret, 's3cr3t')
    local spec = discovery.to_spec(candidate)
    eq(spec.password_env, nil)
    eq(spec.password_cmd, nil)
    eq(h.leaks(spec, 's3cr3t'), false, { fail_reason = 'the password reached the spec' })
  end)

  it('never writes a discovered password, or the connection itself, to the file', function()
    local base = vim.fn.tempname()
    vim.fn.mkdir(base, 'p')
    local options =
      require('dblens.config').setup({ connections_file = base .. '/connections.json' })
    local spec = discovery.to_spec(url_candidate())

    local ok, err = connections.save(options, { spec })
    eq(ok, true, { fail_reason = tostring(err) })
    local written = assert(io.open(options.connections_file, 'r'), 'nothing was written')
    local text = written:read('*a')
    written:close()
    eq(text:find('s3cr3t', 1, true), nil, { fail_reason = 'the password was persisted' })
    eq(text:find('appdb', 1, true), nil, { fail_reason = 'the connection was persisted' })
  end)

  it('gives every candidate a unique name, and never one a real connection owns', function()
    local root = vim.fn.tempname()
    write(root .. '/db/dev.sqlite3', SQLITE_HEADER)
    write(root .. '/other/dev.sqlite3', SQLITE_HEADER)
    local box = h.capture()
    discovery.scan({ root = root, taken = { 'db/dev.sqlite3' } }, box.sink)
    vim.wait(5000, function()
      return box.called
    end)
    local names = {}
    for _, candidate in ipairs(box[1]) do
      eq(names[candidate.name], nil, { fail_reason = 'duplicate candidate name' })
      names[candidate.name] = true
    end
    eq(names['db/dev.sqlite3'], nil, { fail_reason = 'a taken name was handed out again' })
    eq(names['db/dev.sqlite3 (2)'], true)
  end)

  it('drops a candidate that would not validate as a connection', function()
    -- A percent-encoded backtick decodes into a path `dblens.path` refuses, so the candidate is
    -- never offered rather than reaching a client at connect time.
    local line = 'DATABASE_URL=sqlite:///srv/ba%60d.db\n'
    eq(#env.candidates(line, { source = '.env', dir = '/srv' }), 1, {
      fail_reason = 'the parser should still produce the raw candidate',
    })
    local root = vim.fn.tempname()
    write(root .. '/.env', line)
    local found, report = scan(root)
    eq(#found, 0)
    eq(report.skipped, 1)
  end)
end)

describe('discovery: connecting what was found', function()
  --- A `.env` candidate with a password, as `env.candidates` produces one.
  local function network_candidate()
    return {
      name = 'DATABASE_URL',
      kind = 'postgres',
      origin = 'env',
      source = '.env',
      detail = '(postgres, localhost:5432/appdb, from .env)',
      target = { host = 'localhost', port = 5432, user = 'app', database = 'appdb' },
      secret = 'urlsecret',
    }
  end

  it('gives the discovered password to the client, and to nothing else', function()
    h.with_fake_exec(function()
      return {}
    end, function(_, calls)
      local app = require('dblens.app')
      local base = vim.fn.tempname()
      vim.fn.mkdir(base, 'p')
      local options = require('dblens.config').setup({
        connections_file = base .. '/connections.json',
        history_file = base .. '/history.json',
        state_file = base .. '/session.json',
        discovery = { auto = false },
      })
      app.open()
      local state = app.state()
      assert(state, 'app.open left no state')

      app.connect_discovered(network_candidate())
      vim.wait(2000, function()
        return state.session ~= nil
      end, 10)
      assert(state.session, 'the discovered candidate did not connect')

      eq(state.session.spec.name, 'DATABASE_URL')
      eq(state.session:is_read_only(), true, { fail_reason = 'a discovered connection must lock' })
      -- The password reaches the client through the environment, which is the only place it goes.
      eq(calls[1].spec.env.PGPASSWORD, 'urlsecret')
      eq(h.leaks(state.session.spec, 'urlsecret'), false, {
        fail_reason = 'the password reached the spec',
      })

      -- Even asked to save the WHOLE live list, the file gets nothing discovered.
      local ok, err = connections.save(options, state.specs)
      eq(ok, true, { fail_reason = tostring(err) })
      local written = assert(io.open(options.connections_file, 'r'))
      local text = written:read('*a')
      written:close()
      eq(text:find('urlsecret', 1, true), nil, { fail_reason = 'the password was persisted' })
      eq(text:find('DATABASE_URL', 1, true), nil, {
        fail_reason = 'the discovered connection was persisted',
      })

      app.close()
      -- Nor is it remembered as the session to restore: it will not exist next time.
      eq(io.open(options.state_file, 'r'), nil, {
        fail_reason = 'a discovered connection was saved as the restorable session',
      })
    end)
  end)
end)

describe('discovery: the workspace root', function()
  it('is the git repository the path is in', function()
    local root = fixture_workspace()
    vim.fn.mkdir(root .. '/deep/inside', 'p')
    eq(discovery.root(root .. '/deep/inside'), vim.fs.normalize(root))
  end)

  it('is the directory itself when there is no repository', function()
    local plain = vim.fn.tempname()
    vim.fn.mkdir(plain, 'p')
    eq(discovery.root(plain), vim.fs.normalize(plain))
  end)
end)
