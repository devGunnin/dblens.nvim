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

  --- Not byte-for-byte: the file is re-encoded on every write, so key order and hand formatting
  --- go. Every field of every untouched entry, and its position, is what survives.
  it('deletes an entry `load` refuses, leaving its neighbours field-for-field', function()
    local options = scratch()
    local hand_written = { name = 'wrong', kind = 'postgres', comment = 'keep me' }
    store(options, { GOOD, hand_written, { name = 'third', kind = 'sqlite', path = '/tmp/t.db' } })
    local ok, err = connections.put(options, 'wrong', nil)
    eq(ok, true, { fail_reason = tostring(err) })
    eq(vim.json.decode(read_file(options.connections_file)), {
      GOOD,
      { name = 'third', kind = 'sqlite', path = '/tmp/t.db' },
    }, { fail_reason = 'a neighbour was changed, dropped or reordered' })
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

--- The file the manager exists to REPAIR is by definition not a well-formed one. Every case here
--- works on a connections.json a hand-edit or an interrupted write could plausibly leave behind.
describe('an imperfect connections.json', function()
  --- A stray scalar, a JSON null and an entry with no name at all, either side of a good one.
  local MALFORMED = '["oops",{"name":"good","kind":"sqlite","path":"%s"},null,{"kind":"sqlite"}]'

  local function store_malformed(options)
    write_file(GOOD.path, '')
    write_file(options.connections_file, MALFORMED:format(GOOD.path))
  end

  it('lists every element, the ones that are not objects included', function()
    local options = scratch()
    store_malformed(options)
    local rows = manager.rows({ options = options, specs = {} })
    eq(#rows, 4, { fail_reason = 'an element of the file is missing from the list' })
    eq({ rows[1].index, rows[2].index, rows[3].index, rows[4].index }, { 1, 2, 3, 4 })
    eq(rows[2].name, 'good')
    eq(rows[2].health.state, 'ok')
    for _, at in ipairs({ 1, 3, 4 }) do
      eq(rows[at].name, nil, { fail_reason = 'a broken entry was given a usable name' })
      eq(rows[at].health.state, 'broken', { fail_reason = 'the broken entry is not flagged' })
    end
  end)

  it('renders and opens rather than throwing a traceback', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      local app = require('dblens.app')
      local options = scratch()
      store_malformed(options)
      app.open()
      local state = app.state()
      local rows = manager.rows(state)
      local lines = manager.render(rows, nil, nil)
      local text = table.concat(lines, '\n')
      neq(text:find('not an object', 1, true), nil, { fail_reason = text })
      neq(text:find('(no name)', 1, true), nil, { fail_reason = text })
      local popup = manager.open(state)
      neq(popup, nil, { fail_reason = ':DbLensConnections did not open on a malformed file' })
      popup.close()
      app.close()
    end)
  end)

  it('deletes a broken element by its position, leaving the good one', function()
    local options = scratch()
    store_malformed(options)
    local said = notices(function()
      -- The trailing nameless object first, so the earlier positions stay where they are.
      require('dblens.ui.form').remove(options, 4)
      require('dblens.ui.form').remove(options, 3)
      require('dblens.ui.form').remove(options, 1)
    end)
    eq(errors_among(said), {}, { fail_reason = vim.inspect(said) })
    local text = read_file(options.connections_file)
    eq(text:find('oops', 1, true), nil, { fail_reason = text })
    eq(text:find('null', 1, true), nil, { fail_reason = text })
    eq(vim.json.decode(text), { { name = 'good', kind = 'sqlite', path = GOOD.path } })
  end)

  it('deletes an entry whose name is a number, with no assert on the way', function()
    local options = scratch()
    store(options, { { name = 5, kind = 'sqlite', path = '/tmp/x.db' }, GOOD })
    local rows = manager.rows({ options = options, specs = {} })
    eq(rows[1].name, nil, { fail_reason = 'a numeric name was taken for a usable one' })
    neq(rows[1].label:find('5', 1, true), nil, {
      fail_reason = 'the broken name is not shown, so it cannot be found in the file',
    })
    local said = notices(function()
      require('dblens.ui.form').remove(options, 1)
    end)
    eq(errors_among(said), {}, { fail_reason = vim.inspect(said) })
    eq(read_file(options.connections_file):find('"name":5', 1, true), nil)
  end)

  it('keeps two entries under one name apart, and deletes exactly one of them', function()
    local options = scratch()
    store(options, {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
      { name = 'other', kind = 'sqlite', path = '/tmp/c.db' },
    })
    local rows = manager.rows({ options = options, specs = {} })
    eq(#rows, 3)
    neq(rows[2].health.reason:find('duplicate', 1, true), nil, { fail_reason = 'not flagged' })
    neq(rows[1].cells[3], rows[2].cells[3], { fail_reason = 'the two rows are indistinguishable' })

    local ok, err = connections.put_at(options, 2, nil)
    eq(ok, true, { fail_reason = tostring(err) })
    eq(vim.json.decode(read_file(options.connections_file)), {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'other', kind = 'sqlite', path = '/tmp/c.db' },
    }, { fail_reason = 'deleting one duplicate took the other with it' })
  end)

  it('replaces only the duplicate it was pointed at', function()
    local options = scratch()
    store(options, {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
    })
    local ok, err =
      connections.put_at(options, 2, { name = 'dup', kind = 'sqlite', path = '/tmp/z.db' })
    eq(ok, true, { fail_reason = tostring(err) })
    local list = vim.json.decode(read_file(options.connections_file))
    eq(#list, 2, { fail_reason = 'editing a duplicate changed how many entries there are' })
    eq({ list[1].path, list[2].path }, { '/tmp/a.db', '/tmp/z.db' })
  end)

  it('shows `?` rather than a Lua table address for a field that is an object', function()
    local options = scratch()
    write_file(
      options.connections_file,
      '[{"name":"junk","kind":"postgres","host":{"a":1},"port":"nope","database":"d"}]'
    )
    local rows = manager.rows({ options = options, specs = {} })
    eq(rows[1].cells[3], '?', { fail_reason = 'the target cell reads ' .. rows[1].cells[3] })
    eq(rows[1].health.state, 'broken')
  end)

  it('calls a hand-written plaintext password what it is, not "none"', function()
    local options = scratch()
    store(options, { { name = 'bad', kind = 'sqlite', path = '/tmp/x.db', password = 'hunter2' } })
    local rows = manager.rows({ options = options, specs = {} })
    eq(rows[1].cells[5], 'plaintext!', { fail_reason = rows[1].cells[5] })
    -- The value itself is still never rendered.
    eq(h.leaks(rows[1].cells, 'hunter2'), false, { fail_reason = 'the password reached a row' })
  end)

  it('deletes ONE entry when two share the name it was given', function()
    local options = scratch()
    store(options, {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
    })
    local ok, err = connections.put(options, 'dup', nil)
    eq(ok, true, { fail_reason = tostring(err) })
    eq(vim.json.decode(read_file(options.connections_file)), {
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
    }, { fail_reason = 'deleting `dup` took both entries named `dup`' })
  end)

  it('replaces ONE entry when two share the name it was given', function()
    local options = scratch()
    store(options, {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
    })
    local ok, err =
      connections.put(options, 'dup', { name = 'dup', kind = 'sqlite', path = '/tmp/z.db' })
    eq(ok, true, { fail_reason = tostring(err) })
    eq(vim.json.decode(read_file(options.connections_file)), {
      { name = 'dup', kind = 'sqlite', path = '/tmp/z.db' },
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
    }, { fail_reason = 'the replacement was written once per matching entry' })
  end)

  it('refuses to rename an entry onto a name another one already holds', function()
    local options = scratch()
    store(options, {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'other', kind = 'sqlite', path = '/tmp/b.db' },
    })
    local ok, err =
      connections.put_at(options, 2, { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' })
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

      -- Addressed by its position in the file: `tactica` is the second stored entry.
      local said = notices(function()
        require('dblens.ui.form').remove(options, 2)
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
      require('dblens.ui.form').remove_named(options, 'fromconfig')
    end)
    neq(errors_among(said)[1], nil)
    neq(errors_among(said)[1]:find('setup{}', 1, true), nil, { fail_reason = said[1].message })

    -- And it occupies no position in the file, so `dd` has nothing to address either.
    local rows = manager.rows({ options = options, specs = {} })
    eq(rows[1].source, 'config')
    eq(rows[1].index, nil, { fail_reason = 'a setup{} connection was given a file position' })
    local problem = manager.editable_problem(rows[1])
    neq(problem, nil, { fail_reason = 'the manager would let `dd` reach a setup{} connection' })
    neq(problem:find('setup{}', 1, true), nil, { fail_reason = problem })
  end)

  it('refuses `:DbLensRemove` a name two stored entries share, rather than guessing', function()
    local options = scratch()
    store(options, {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
    })
    local before = read_file(options.connections_file)
    local said = notices(function()
      require('dblens.ui.form').remove_named(options, 'dup')
    end)
    local problem = errors_among(said)[1]
    neq(problem, nil, { fail_reason = 'an ambiguous name was deleted anyway' })
    neq(problem:find('DbLensConnections', 1, true), nil, {
      fail_reason = 'the message must point at where the right entry can be picked: ' .. problem,
    })
    eq(read_file(options.connections_file), before, { fail_reason = 'the file was changed' })
  end)

  it('removes by name when exactly one stored entry answers to it', function()
    h.with_fake_exec(function()
      return {}
    end, function()
      local options = scratch()
      store(options, { GOOD, BROKEN })
      require('dblens.app').open()
      local said = notices(function()
        require('dblens.ui.form').remove_named(options, 'tactica')
      end)
      eq(errors_among(said), {}, { fail_reason = vim.inspect(said) })
      eq(read_file(options.connections_file):find('tactica', 1, true), nil)
      require('dblens.app').close()
    end)
  end)

  it('refuses a position the connections file does not have', function()
    local options = scratch()
    store(options, { GOOD })
    local said = notices(function()
      require('dblens.ui.form').remove(options, 2)
    end)
    neq(errors_among(said)[1], nil, { fail_reason = 'deleting nothing reported success' })
    neq(errors_among(said)[1]:find('position 2', 1, true), nil, {
      fail_reason = errors_among(said)[1],
    })
    neq(read_file(options.connections_file):find('local', 1, true), nil, {
      fail_reason = 'the file was rewritten anyway',
    })
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

--- The connections file is the only record of every saved connection, and there is no backup: a
--- write that dies halfway must lose nothing and must never report that it saved.
describe('connections: writing the file', function()
  --- Run `fn` with one `vim.uv` call replaced, so a syscall failure can be exercised without
  --- depending on the machine the suite runs on.
  local function with_uv_failure(name, replacement, fn)
    local real = vim.uv[name]
    vim.uv[name] = replacement
    local ok, err = pcall(fn)
    vim.uv[name] = real
    assert(ok, tostring(err))
  end

  --- Every `.tmp` file left beside the connections file.
  local function leftovers(options)
    local dir = vim.fn.fnamemodify(options.connections_file, ':h')
    return vim.fn.globpath(dir, '*.tmp', true, true)
  end

  it('leaves the original file exactly as it was when the rename fails', function()
    local options = scratch()
    store(options, { GOOD })
    local before = read_file(options.connections_file)
    local ok, err
    with_uv_failure('fs_rename', function()
      return nil, 'EIO: injected'
    end, function()
      ok, err =
        connections.put(options, 'second', { name = 'second', kind = 'sqlite', path = '/tmp/s.db' })
    end)
    eq(ok, false, { fail_reason = 'a failed write reported that it saved' })
    neq(err:find('could not replace', 1, true), nil, { fail_reason = tostring(err) })
    eq(read_file(options.connections_file), before, { fail_reason = 'the original file changed' })
    eq(leftovers(options), {}, { fail_reason = 'a temp file was left behind' })
  end)

  it('leaves the original file exactly as it was when the write is short', function()
    local options = scratch()
    store(options, { GOOD })
    local before = read_file(options.connections_file)
    local ok, err
    with_uv_failure('fs_write', function()
      return nil, 'ENOSPC: injected'
    end, function()
      ok, err =
        connections.put(options, 'second', { name = 'second', kind = 'sqlite', path = '/tmp/s.db' })
    end)
    eq(ok, false, { fail_reason = 'a failed write reported that it saved' })
    neq(err:find('ENOSPC', 1, true), nil, { fail_reason = tostring(err) })
    eq(read_file(options.connections_file), before, { fail_reason = 'the original file changed' })
    eq(leftovers(options), {}, { fail_reason = 'a temp file was left behind' })
  end)

  it('reports a real unwritable directory rather than saying it saved', function()
    local options = scratch()
    store(options, { GOOD })
    local before = read_file(options.connections_file)
    local dir = vim.fn.fnamemodify(options.connections_file, ':h')
    vim.fn.setfperm(dir, 'r-x------')
    local probe = vim.uv.fs_open(dir .. '/dblens-probe', 'w', tonumber('600', 8))
    if probe then
      -- Running as a user the mode does not bind (root): there is no real failure to observe.
      vim.uv.fs_close(probe)
      vim.uv.fs_unlink(dir .. '/dblens-probe')
      vim.fn.setfperm(dir, 'rwx------')
      MiniTest.add_note(
        'the connections directory stayed writable; the real-failure proof did not run'
      )
      return
    end
    local ok, err =
      connections.put(options, 'second', { name = 'second', kind = 'sqlite', path = '/tmp/s.db' })
    vim.fn.setfperm(dir, 'rwx------')
    eq(ok, false, { fail_reason = 'a failed write reported that it saved' })
    eq(type(err), 'string')
    eq(read_file(options.connections_file), before, { fail_reason = 'the original file changed' })
    eq(leftovers(options), {}, { fail_reason = 'a temp file was left behind' })
  end)

  it('keeps the file owner-only, from the moment it is created', function()
    local options = scratch()
    local ok, err = connections.put(options, GOOD.name, GOOD)
    eq(ok, true, { fail_reason = tostring(err) })
    eq(vim.fn.getfperm(options.connections_file), 'rw-------')
    eq(leftovers(options), {}, { fail_reason = 'a temp file was left behind' })
  end)

  it('never writes the VALUE a `password_env` names, only the name', function()
    local options = scratch()
    vim.env.DBLENS_WRITE_PROBE = 'sup3rs3cr3t'
    local spec = {
      name = 'pg',
      kind = 'postgres',
      host = 'h',
      user = 'u',
      database = 'd',
      password_env = 'DBLENS_WRITE_PROBE',
    }
    local ok, err = connections.put(options, spec.name, spec)
    eq(ok, true, { fail_reason = tostring(err) })
    local bytes = read_file(options.connections_file)
    vim.env.DBLENS_WRITE_PROBE = nil
    eq(bytes:find('sup3rs3cr3t', 1, true), nil, { fail_reason = 'the secret reached the file' })
    neq(bytes:find('DBLENS_WRITE_PROBE', 1, true), nil, { fail_reason = bytes })
  end)
end)

describe('form: editing a saved connection', function()
  --- Answer `form.edit`'s questions in order: a value for `vim.ui.input`, a 1-based index for
  --- `vim.ui.select`.
  ---@return { message: string, level: integer? }[] said, table? saved
  local function edit_with(options, index, answers)
    local at, saved = 0, nil
    local real_select, real_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, _opts, on_choice)
      at = at + 1
      local pick = answers[at]
      assert(type(pick) == 'number', ('answer %d is not a selection'):format(at))
      on_choice(items[pick], pick)
    end
    vim.ui.input = function(_opts, on_confirm)
      at = at + 1
      on_confirm(answers[at])
    end
    local said = notices(function()
      require('dblens.ui.form').edit(options, index, function(spec)
        saved = spec
      end)
    end)
    vim.ui.select, vim.ui.input = real_select, real_input
    return said, saved
  end

  it('keeps a key the user hand-wrote that no question asks about', function()
    local options = scratch()
    store(options, {
      GOOD,
      {
        name = 'sq',
        kind = 'sqlite',
        path = '/tmp/edit-me.db',
        comment = 'do not lose me',
        tunnel = { host = 'bastion' },
      },
    })
    -- path, then "no password", then read-only.
    local said, saved = edit_with(options, 2, { '/tmp/edited.db', 1, 1 })
    eq(errors_among(said), {}, { fail_reason = vim.inspect(said) })
    neq(saved, nil, { fail_reason = 'the edit did not save' })
    local list = vim.json.decode(read_file(options.connections_file))
    eq(#list, 2)
    eq(list[2].path, '/tmp/edited.db', { fail_reason = 'the edited field did not land' })
    eq(list[2].comment, 'do not lose me', { fail_reason = 'a hand-written key was dropped' })
    eq(list[2].tunnel, { host = 'bastion' }, { fail_reason = 'a hand-written key was dropped' })
    eq(list[1].name, 'local', { fail_reason = 'the neighbour was disturbed' })
  end)

  it('edits the duplicate it was pointed at, not the first one under that name', function()
    local options = scratch()
    store(options, {
      { name = 'dup', kind = 'sqlite', path = '/tmp/a.db' },
      { name = 'dup', kind = 'sqlite', path = '/tmp/b.db' },
    })
    local said = edit_with(options, 2, { '/tmp/z.db', 1, 1 })
    eq(errors_among(said), {}, { fail_reason = vim.inspect(said) })
    local list = vim.json.decode(read_file(options.connections_file))
    eq(#list, 2, { fail_reason = 'editing a duplicate changed how many entries there are' })
    eq({ list[1].path, list[2].path }, { '/tmp/a.db', '/tmp/z.db' })
  end)

  it('asks for a name when the stored one cannot be used, and stores the repair', function()
    local options = scratch()
    store(options, { { name = '', kind = 'sqlite', path = '/tmp/x.db' } })
    -- name, path, "no password", read-only.
    local said, saved = edit_with(options, 1, { 'repaired', '/tmp/x.db', 1, 1 })
    eq(errors_among(said), {}, { fail_reason = vim.inspect(said) })
    eq(saved and saved.name, 'repaired')
    eq(vim.json.decode(read_file(options.connections_file))[1].name, 'repaired')
  end)

  it('says which entry it cannot edit when the element is not an object at all', function()
    local options = scratch()
    write_file(options.connections_file, '["oops"]')
    local said = edit_with(options, 1, {})
    neq(errors_among(said)[1], nil, { fail_reason = 'editing a stray scalar said nothing' })
    neq(errors_among(said)[1]:find('position 1', 1, true), nil, {
      fail_reason = errors_among(said)[1],
    })
    eq(read_file(options.connections_file), '["oops"]', { fail_reason = 'the file was rewritten' })
  end)
end)
