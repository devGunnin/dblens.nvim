--- The connections store, the manager built on it, and the two failures that made a hand-added
--- connection unusable: it errored on every start, and there was no way to see or delete it.
---
--- Every case here works on a scratch connections file, so nothing reads or writes the machine's
--- own dblens state.
local h = require('helpers')
local connections = require('dblens.connections')
local manager = require('dblens.ui.manager')

local eq, neq = h.eq, h.neq

--- Config with every file this touches inside the test's own temp directory.
local function scratch(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return require('dblens.config').setup(vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
    -- Opening with no connections would otherwise scan the machine the suite runs on.
    discovery = { auto = false },
  }, extra or {}))
end

local function write_file(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local file = assert(io.open(path, 'w'), 'cannot write ' .. path)
  file:write(text)
  file:close()
end

local function read_file(path)
  local file = io.open(path, 'r')
  if not file then
    return ''
  end
  local text = file:read('*a')
  file:close()
  return text
end

--- The connection the incident was about: a `.env` file name where a variable name belongs, and
--- a host with the port glued onto it.
local BROKEN = {
  name = 'tactica',
  kind = 'postgres',
  host = 'localhost:5432',
  user = 'app',
  database = 'app',
  password_env = '.env',
  read_only = false,
}

local GOOD = { name = 'local', kind = 'sqlite', path = '/tmp/dblens-manager-test.db' }

local function store(options, specs)
  write_file(options.connections_file, vim.json.encode(specs))
end

--- Everything `vim.notify` was handed while `fn` ran.
---@return { message: string, level: integer? }[]
local function notices(fn)
  local said = {}
  local real = vim.notify
  vim.notify = function(message, level)
    said[#said + 1] = { message = message, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = real
  assert(ok, tostring(err))
  return said
end

local function errors_among(said)
  local out = {}
  for _, entry in ipairs(said) do
    if entry.level == vim.log.levels.ERROR then
      out[#out + 1] = entry.message
    end
  end
  return out
end

describe('connections: health without connecting', function()
  it('reports a connection whose environment variable is not set', function()
    local options = scratch()
    vim.env.DBLENS_MANAGER_ABSENT = nil
    local spec = {
      name = 'p',
      kind = 'postgres',
      database = 'app',
      password_env = 'DBLENS_MANAGER_ABSENT',
      source = 'file',
    }
    local health = connections.health(spec)
    eq(health.state, 'broken')
    neq(health.reason:find('DBLENS_MANAGER_ABSENT', 1, true), nil, { fail_reason = health.reason })
    eq(options ~= nil, true)
  end)

  it('says a `.env` is a file, and what to give instead', function()
    local health = connections.health(vim.tbl_extend('force', BROKEN, { host = 'localhost' }))
    eq(health.state, 'broken')
    local reason = health.reason
    neq(reason:find('file name', 1, true), nil, { fail_reason = reason })
    neq(reason:find('PGPASSWORD', 1, true), nil, {
      fail_reason = 'the message must name what to give instead: ' .. reason,
    })
  end)

  it('reports a host with the port glued onto it, and the split it should be', function()
    vim.env.DBLENS_MANAGER_SET = 'x'
    local spec = vim.tbl_extend('force', BROKEN, { password_env = 'DBLENS_MANAGER_SET' })
    local health = connections.health(spec)
    eq(health.state, 'broken')
    neq(health.reason:find('port', 1, true), nil, { fail_reason = health.reason })
    neq(health.reason:find('5432', 1, true), nil, { fail_reason = health.reason })
    vim.env.DBLENS_MANAGER_SET = nil
  end)

  it('leaves a password command unchecked rather than running it to draw a list', function()
    local spec = {
      name = 'p',
      kind = 'postgres',
      database = 'app',
      password_cmd = { 'pass', 'show', 'db' },
      source = 'file',
    }
    -- Running it could raise a passphrase prompt; the connection proves it instead.
    eq(connections.health(spec).state, 'unknown')
  end)

  it('is fine with a connection that needs no password', function()
    write_file(GOOD.path, '')
    eq(connections.health(vim.tbl_extend('force', GOOD, { source = 'file' })).state, 'ok')
  end)

  it('splits only an unambiguous host:port, never an IPv6 literal', function()
    eq({ connections.split_host_port('localhost:5432') }, { 'localhost', 5432 })
    eq(connections.split_host_port('::1'), nil)
    eq(connections.split_host_port('2001:db8::1'), nil)
    eq(connections.split_host_port('/var/run/postgresql'), nil)
    eq(connections.split_host_port('db:99999'), nil)
  end)
end)

describe('connections: the store keeps what it cannot use', function()
  it('lists an entry validation refuses, which `load` drops', function()
    local options = scratch()
    store(options, { GOOD, { name = 'wrong', kind = 'postgres' } })
    local specs = connections.load(options)
    eq(#specs, 1, { fail_reason = 'the invalid entry must not be usable' })

    local entries = connections.entries(options)
    eq(#entries, 2, { fail_reason = 'the manager must be able to see the invalid entry' })
    eq(entries[2].spec.name, 'wrong')
    eq(type(entries[2].problem), 'string')
  end)

  it('deletes an entry `load` refuses, leaving its neighbours byte-for-byte', function()
    local options = scratch()
    store(options, { GOOD, { name = 'wrong', kind = 'postgres' } })
    local ok, err = connections.put(options, 'wrong', nil)
    eq(ok, true, { fail_reason = tostring(err) })
    local text = read_file(options.connections_file)
    eq(text:find('wrong', 1, true), nil)
    neq(text:find('local', 1, true), nil, { fail_reason = 'the good connection was dropped too' })
  end)

  it('refuses to author a plaintext password rather than rewriting the file around one', function()
    local options = scratch()
    store(options, { { name = 'bad', kind = 'sqlite', path = '/tmp/x.db', password = 'hunter2' } })
    local ok, err = connections.put(options, 'other', GOOD)
    eq(ok, false)
    neq(err:find('plaintext', 1, true), nil, { fail_reason = tostring(err) })
    neq(read_file(options.connections_file):find('hunter2', 1, true), nil, {
      fail_reason = 'the file was rewritten anyway',
    })
  end)

  it('refuses a name another entry already owns', function()
    local options = scratch()
    store(options, { GOOD })
    local ok, err = connections.put(options, 'other', vim.tbl_extend('force', GOOD, {}))
    eq(ok, false)
    neq(err:find('already exists', 1, true), nil, { fail_reason = tostring(err) })
  end)
end)

describe('manager: the list', function()
  it('shows every saved connection with its engine, target, mode and password source', function()
    local options = scratch()
    write_file(GOOD.path, '')
    store(options, { GOOD, BROKEN })
    local state = { options = options, specs = {}, icons = nil }

    local rows = manager.rows(state)
    eq(#rows, 2)
    eq(rows[1].cells[1], 'local')
    eq(rows[1].cells[2], 'sqlite')
    eq(rows[1].cells[4], 'LOCKED', { fail_reason = 'a connection with no `read_only` is locked' })
    eq(rows[1].cells[5], 'none')
    eq(rows[1].health.state, 'ok')

    eq(rows[2].cells[1], 'tactica')
    eq(rows[2].cells[4], 'EDIT', { fail_reason = 'read_only = false is EDIT' })
    eq(rows[2].cells[5], '$.env', { fail_reason = 'the reference is shown, never a value' })
    eq(rows[2].health.state, 'broken')
  end)

  it('renders the broken one flagged, with the reason beside it', function()
    local options = scratch()
    store(options, { BROKEN })
    local state = { options = options, specs = {} }
    local rows = manager.rows(state)
    local lines, row_at = manager.render(rows, nil, nil)
    local text = table.concat(lines, '\n')
    eq(row_at[1], 1, { fail_reason = 'the first row is not where the cursor lands' })
    eq(row_at[2], 1, { fail_reason = 'the reason line must belong to its row' })
    neq(text:find('tactica', 1, true), nil)
    neq(text:find('!', 1, true), nil, { fail_reason = 'the broken row carries no flag: ' .. text })
    neq(text:find(rows[1].health.reason, 1, true), nil, {
      fail_reason = 'the reason is not shown beside the row: ' .. text,
    })
  end)

  it('marks a discovered connection and never counts it as saved', function()
    local options = scratch()
    store(options, { GOOD })
    write_file(GOOD.path, '')
    local discovered =
      { name = 'DATABASE_URL', kind = 'postgres', database = 'app', source = 'discovered' }
    local rows = manager.rows({ options = options, specs = { discovered } })
    eq(#rows, 2)
    eq(rows[2].source, 'discovered')
    neq(rows[2].cells[1]:find('discovered', 1, true), nil, { fail_reason = rows[2].cells[1] })
    eq(read_file(options.connections_file):find('DATABASE_URL', 1, true), nil)
  end)

  it('opens over the app state and binds its own actions', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      local app = require('dblens.app')
      local options = scratch()
      store(options, { BROKEN })
      app.open()
      local state = app.state()
      assert(state, 'app.open left no state')
      local popup = manager.open(state)
      local keys = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(popup.buf, 'n')) do
        keys[map.lhs] = true
      end
      for _, lhs in ipairs({ '<CR>', 'e', 'dd', 'a', 'q', '?' }) do
        eq(keys[lhs], true, { fail_reason = ('the manager does not bind `%s`'):format(lhs) })
      end
      popup.close()
      app.close()
    end)
  end)
end)

describe('manager: deleting a connection', function()
  it('removes it from the file and stops the saved session pointing at it', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      local app = require('dblens.app')
      local options = scratch()
      store(options, { GOOD, BROKEN })
      write_file(options.state_file, vim.json.encode({ connection = 'tactica' }))
      app.open()

      local said = notices(function()
        require('dblens.ui.form').remove(options, 'tactica')
      end)
      eq(errors_among(said), {}, { fail_reason = 'deleting reported an error' })

      local text = read_file(options.connections_file)
      eq(text:find('tactica', 1, true), nil, { fail_reason = 'it is still in the file' })
      neq(text:find('local', 1, true), nil, { fail_reason = 'the other connection went with it' })
      eq(require('dblens.state').load(options).connection, nil, {
        fail_reason = 'the saved session still points at the deleted connection',
      })
      eq(require('dblens.connections').find(app.state().specs, 'tactica'), nil, {
        fail_reason = 'the live list still offers it',
      })
      app.close()
    end)
  end)

  it('refuses to delete one that comes from setup{}', function()
    local options =
      scratch({ connections = { { name = 'fromconfig', kind = 'sqlite', path = '/tmp/c.db' } } })
    local said = notices(function()
      require('dblens.ui.form').remove(options, 'fromconfig')
    end)
    neq(errors_among(said)[1], nil)
    neq(errors_among(said)[1]:find('setup{}', 1, true), nil, { fail_reason = said[1].message })
  end)
end)

--- The form is where the operator's connection came from, so it is where the mistake has to be
--- caught: a host with the port glued on, and a `.env` FILE named as an environment variable.
describe('form: what the add form refuses to store', function()
  --- Answer the form's questions in order. Each answer is either a value for `vim.ui.input` or,
  --- for `vim.ui.select`, the 1-based index of the option to take.
  ---@param answers any[]
  ---@return { message: string, level: integer? }[] said, table? saved, table[] asked
  local function fill_in(options, answers)
    local index, saved, asked = 0, nil, {}
    local real_select, real_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, on_choice)
      index = index + 1
      local at = answers[index]
      assert(type(at) == 'number', ('answer %d is not a selection'):format(index))
      asked[#asked + 1] = { prompt = opts.prompt, items = items }
      on_choice(items[at], at)
    end
    vim.ui.input = function(_opts, on_confirm)
      index = index + 1
      on_confirm(answers[index])
    end
    local said = notices(function()
      require('dblens.ui.form').add(options, function(spec)
        saved = spec
      end)
    end)
    vim.ui.select, vim.ui.input = real_select, real_input
    return said, saved, asked
  end

  --- Where postgres sits in the sorted kind list; it asks host, port, user, database, sslmode.
  local POSTGRES = 5

  it('splits a host typed as `host:port` into the two fields it is', function()
    local options = scratch()
    local said, saved =
      fill_in(options, { POSTGRES, 'p', 'localhost:5432', '', '', 'app', '', 1, 1 })
    eq(errors_among(said), {}, { fail_reason = vim.inspect(said) })
    eq({ saved.host, saved.port }, { 'localhost', 5432 })
    local stored = read_file(options.connections_file)
    neq(stored:find('"host":"localhost"', 1, true), nil, { fail_reason = stored })
    eq(stored:find('localhost:5432', 1, true), nil, { fail_reason = 'the glued host was stored' })
  end)

  it('refuses a host and a port that disagree rather than storing both', function()
    local options = scratch()
    local said, saved = fill_in(options, { POSTGRES, 'p', 'db:5432', '3306', '', 'app', '', 1, 1 })
    eq(saved, nil, { fail_reason = 'the contradictory connection was saved' })
    neq(errors_among(said)[1], nil, { fail_reason = 'nothing was said about it' })
    eq(read_file(options.connections_file), '')
  end)

  it('refuses a `.env` where an environment variable name belongs, and says why', function()
    local options = scratch()
    -- Answer 2 to the password question: "the NAME of an environment variable".
    local said, saved =
      fill_in(options, { POSTGRES, 'p', 'localhost', '', '', 'app', '', 2, '.env' })
    eq(saved, nil, { fail_reason = 'the `.env` password reference was saved' })
    local problem = errors_among(said)[1]
    neq(problem, nil, { fail_reason = 'nothing was said about it' })
    neq(problem:find('file name', 1, true), nil, { fail_reason = problem })
    neq(problem:find('DbLensDiscover', 1, true), nil, {
      fail_reason = 'the message must point at what reads a .env file: ' .. problem,
    })
    eq(read_file(options.connections_file), '')
  end)

  it('offers read-only first, and only an explicit read-write answer unlocks', function()
    local _, locked, asked =
      fill_in(scratch(), { POSTGRES, 'p', 'localhost', '', '', 'app', '', 1, 1 })
    eq(locked.read_only, true, { fail_reason = 'the first access answer must be LOCKED' })
    local access = asked[#asked]
    eq(access.prompt, 'Access')
    neq(access.items[1]:find('read-only', 1, true), nil, {
      fail_reason = 'read-only must be the first, default answer: ' .. access.items[1],
    })

    local _, writable = fill_in(scratch(), { POSTGRES, 'w', 'localhost', '', '', 'app', '', 1, 2 })
    eq(
      writable.read_only,
      false,
      { fail_reason = 'the explicit read-write answer must be honoured' }
    )
  end)
end)

--- The bug this release exists for: a misconfigured connection made `:DbLens` shout on every
--- single start, and session restore was where it shouted loudest.
describe('boot: a connection that cannot resolve its secret', function()
  local function open_with()
    local app = require('dblens.app')
    local said = notices(function()
      app.open()
    end)
    return app, said
  end

  it('opens dblens with one quiet line and no error at all', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      vim.env.DBLENS_MANAGER_ABSENT = nil
      local options = scratch({ session = { restore = true } })
      store(options, {
        vim.tbl_extend(
          'force',
          BROKEN,
          { host = 'localhost', password_env = 'DBLENS_MANAGER_ABSENT' }
        ),
      })
      write_file(options.state_file, vim.json.encode({ connection = 'tactica' }))

      local app, said = open_with()
      eq(app.is_open(), true, { fail_reason = 'dblens did not open' })
      eq(errors_among(said), {}, { fail_reason = 'the boot still errors' })
      eq(#said, 1, { fail_reason = 'expected one line, got ' .. vim.inspect(said) })
      neq(said[1].message:find('DbLensConnections', 1, true), nil, {
        fail_reason = 'the line must say where to fix it: ' .. said[1].message,
      })
      eq(app.state().session, nil, { fail_reason = 'a broken connection was opened anyway' })
      app.close()
    end)
  end)

  it('says nothing at all when the saved connection no longer exists', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      local options = scratch({ session = { restore = true } })
      write_file(GOOD.path, '')
      store(options, { GOOD })
      write_file(options.state_file, vim.json.encode({ connection = 'deleted' }))
      local app, said = open_with()
      eq(said, {}, { fail_reason = 'restoring a gone connection said ' .. vim.inspect(said) })
      eq(app.is_open(), true)
      app.close()
    end)
  end)

  it('reports connections it cannot load as one line, not one error each', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      local options = scratch()
      store(options, {
        { name = 'a', kind = 'postgres' },
        { name = 'b', kind = 'nosuchengine' },
        GOOD,
      })
      write_file(GOOD.path, '')
      local app, said = open_with()
      eq(errors_among(said), {}, { fail_reason = 'still one error per bad connection' })
      eq(#said, 1, { fail_reason = vim.inspect(said) })
      neq(said[1].message:find('2 connection', 1, true), nil, { fail_reason = said[1].message })
      app.close()
    end)
  end)

  it('still connects the sole connection when it is usable', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      local options = scratch()
      write_file(GOOD.path, '')
      store(options, { GOOD })
      local app = require('dblens.app')
      app.open()
      vim.wait(1000, function()
        return app.state().session ~= nil
      end, 10)
      neq(app.state().session, nil, { fail_reason = 'a healthy sole connection must still open' })
      app.close()
    end)
  end)
end)
