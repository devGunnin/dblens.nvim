--- The controller and its async callbacks — the layer that had no coverage and where closing
--- during a running query left the UI permanently unclosable.
---
--- Each case opens the real UI in a scratch tabpage, drives it over a scripted client double,
--- and asserts on what the user is left holding.
local h = require('helpers')

local eq, neq = h.eq, h.neq

--- Config that keeps every file this touches inside the test's own temp directory.
local function scratch_options(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
    -- Opening with no connections would otherwise scan the machine the suite runs on.
    discovery = { auto = false },
  }, extra or {})
end

--- Open the UI with a session already attached, so a query can be fired immediately.
local function open_with_session(session_mod, extra)
  local app = require('dblens.app')
  require('dblens.config').setup(scratch_options(extra))
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.session = h.fake_session(session_mod, {}, scratch_options(extra))
  return app, state
end

local function augroup_exists()
  return pcall(vim.api.nvim_get_autocmds, { group = 'DbLensLifecycle' })
end

local function dblens_buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_valid(buf) and name:find('dblens: ', 1, true) then
      out[#out + 1] = name
    end
  end
  return out
end

describe('app: closing while a query runs', function()
  it('closes cleanly, kills the client, and releases the tab, buffers and augroup', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local tabs_before = #vim.api.nvim_list_tabpages()
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1')
      eq(#calls, 1, { fail_reason = 'the query must be in flight' })
      eq(state.busy, 'query')

      local ok, err = pcall(app.close)
      eq(ok, true, { fail_reason = 'close raised: ' .. tostring(err) })
      eq(app.state(), nil)
      eq(app.is_open(), false)
      eq(calls[1].cancelled, true, { fail_reason = 'the client process must be killed' })
      eq(#vim.api.nvim_list_tabpages(), tabs_before)
      eq(dblens_buffers(), {})
      eq(augroup_exists(), false)
    end)
  end)

  it('survives the killed client reporting back after the close', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app = open_with_session(session_mod)
      app.run_sql('SELECT 1')
      app.close()
      local ok, err = pcall(calls[1].resume, { ok = false, code = -1, reason = 'cancelled' })
      eq(ok, true, { fail_reason = 'a late callback raised: ' .. tostring(err) })
      eq(app.state(), nil)
    end)
  end)

  it('reopens after a close instead of stacking a second layout', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local tabs_before = #vim.api.nvim_list_tabpages()
      local app = open_with_session(session_mod)
      app.run_sql('SELECT 1')
      app.close()
      calls[1].resume({ ok = false, reason = 'cancelled' })

      require('dblens.config').setup(scratch_options())
      app.open()
      eq(app.is_open(), true)
      eq(#vim.api.nvim_list_tabpages(), tabs_before + 1)
      app.close()
      eq(#vim.api.nvim_list_tabpages(), tabs_before)
    end)
  end)

  it('is idempotent', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app = open_with_session(session_mod)
      app.close()
      eq(pcall(app.close), true)
      eq(app.state(), nil)
    end)
  end)

  it('closes even when dblens owns the only tabpage', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app = open_with_session(session_mod)
      local tab = vim.api.nvim_get_current_tabpage()
      for _, other in ipairs(vim.api.nvim_list_tabpages()) do
        if other ~= tab then
          pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_get_win(other), true)
        end
      end
      eq(#vim.api.nvim_list_tabpages(), 1)
      eq(pcall(app.close), true)
      eq(#vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage()), 1)
      eq(dblens_buffers(), {})
      vim.cmd('tabnew')
    end)
  end)
end)

--- A throw while the UI was being built left `state` set with no layout: `is_open()` said false,
--- `:DbLensClose` reported success and touched nothing, and the tab of dead scratch buffers it
--- had already created stayed for the session — one more on every retry.
describe('app: an open that fails part-way through', function()
  it('leaves no state, no tabpage and no buffers behind', function()
    local app = require('dblens.app')
    local config = require('dblens.config')
    config.setup(scratch_options())
    -- Past validation, so the throw lands inside the layout build where the leak used to be.
    config.get().ui.sidebar.width = 0

    local tabs, bufs = #vim.api.nvim_list_tabpages(), #dblens_buffers()
    for attempt = 1, 3 do
      local ok = pcall(app.open)
      eq(ok, false, { fail_reason = 'the open was supposed to fail' })
      eq(app.state(), nil, { fail_reason = 'a failed open left state behind' })
      eq(app.is_open(), false)
      app.close()
      eq(#vim.api.nvim_list_tabpages(), tabs, {
        fail_reason = ('attempt %d stranded a tabpage'):format(attempt),
      })
      eq(#dblens_buffers(), bufs, {
        fail_reason = ('attempt %d stranded scratch buffers'):format(attempt),
      })
      eq(augroup_exists(), false, { fail_reason = 'the lifecycle augroup outlived the failure' })
    end
    config.setup(scratch_options())
  end)
end)

describe('app: results are routed to the request that asked for them', function()
  it('drops a count that belongs to a superseded view', function()
    h.with_fake_exec(function(call)
      if call.stdin:find('count(*)', 1, true) then
        return { pending = true }
      end
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      local relation = { name = 't', kind = 'table' }
      state.grid.source = { kind = 'relation', relation = relation, label = 't' }
      app.count_rows(relation)
      eq(#calls, 1)

      -- The user filters before the first count lands; the old total must not be installed.
      app.set_filter("a = 'x'")
      calls[1].resume({ stdout = h.wire({ h.record('n'), h.record('999') }) })
      eq(state.grid.paging.total, nil, { fail_reason = 'a stale count overwrote the new paging' })
      app.close()
    end)
  end)

  it('cancels the page fetch already in flight before starting another', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      state.grid.source =
        { kind = 'relation', relation = { name = 't', kind = 'table' }, label = 't' }
      app.fetch_page()
      app.fetch_page()
      eq(#calls, 2)
      eq(calls[1].cancelled, true, { fail_reason = 'the superseded fetch must be cancelled' })
      app.close()
    end)
  end)
end)

describe('app: cancelling an editor query', function()
  it('reaches the client the editor actually started', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app = open_with_session(session_mod)
      app.run_sql('SELECT pg_sleep(60)')
      eq(#calls, 1)
      app.cancel()
      eq(calls[1].cancelled, true, { fail_reason = 'editor queries were not cancellable' })
      calls[1].resume({ ok = false, reason = 'cancelled' })
      app.close()
    end)
  end)
end)

describe('app: read-only and confirmation reach ad-hoc SQL', function()
  it('refuses a hidden write on a read-only connection without spawning a client', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      state.session = h.fake_session(session_mod, { read_only = true }, scratch_options())
      app.run_sql('WITH d AS (DELETE FROM t RETURNING *) SELECT count(*) FROM d')
      eq(#calls, 0, { fail_reason = 'a read-only connection executed a CTE delete' })
      app.close()
    end)
  end)

  it('refuses EXPLAIN ANALYZE of a DELETE on a read-only connection', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      state.session = h.fake_session(
        session_mod,
        { kind = 'postgres', database = 'db', read_only = true },
        scratch_options()
      )
      app.run_sql('DELETE FROM t WHERE a = 1', { explain = true, analyze = true })
      eq(#calls, 0, { fail_reason = 'EXPLAIN ANALYZE executed a DELETE on a read-only connection' })
      app.close()
    end)
  end)
end)

describe('ui: the winbar option is honoured', function()
  it('leaves the winbar empty when it is switched off', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod, { ui = { winbar = false } })
      app.render()
      for _, pane in ipairs({ 'sidebar', 'editor', 'results' }) do
        eq(vim.wo[state.layout.wins[pane]].winbar, '', { fail_reason = pane .. ' drew a winbar' })
      end
      app.close()
    end)
  end)

  it('draws one when it is on', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      app.render()
      neq(vim.wo[state.layout.wins.results].winbar, '')
      app.close()
    end)
  end)
end)

describe('ui: the help overlay fits the screen', function()
  local help = require('dblens.ui.help')
  local keymaps = require('dblens.keymaps')

  it('never runs below the fold, down to 80x24', function()
    local options = require('dblens.config').setup(scratch_options())
    for _, scope in ipairs({ 'sidebar', 'results', 'editor' }) do
      -- 80x24 leaves 17 rows inside the float at the default max_height.
      local available = math.floor(24 * options.ui.float.max_height) - 2
      local lines = help.layout(help.blocks(scope, options), available)
      eq(
        #lines <= available,
        true,
        { fail_reason = ('%s: %d lines into %d rows'):format(scope, #lines, available) }
      )
    end
  end)

  it('is generated from the registry, so it cannot drift from what is bound', function()
    local options = require('dblens.config').setup(scratch_options())
    local shown = {}
    for _, block in ipairs(help.blocks('results', options)) do
      for _, row in ipairs(block.rows) do
        shown[row.left] = row.right
      end
    end
    for _, scope in ipairs({ 'results', 'global' }) do
      for _, entry in ipairs(keymaps.resolve(scope, options.keymaps[scope])) do
        local lhs = table.concat(entry.lhs, ' / ')
        eq(shown[lhs], entry.spec.desc, { fail_reason = 'help is missing ' .. lhs })
      end
    end
  end)

  it('follows a user override rather than the default lhs', function()
    local options = require('dblens.config').setup(
      scratch_options({ keymaps = { results = { refresh = '<F5>' } } })
    )
    local found = false
    for _, block in ipairs(help.blocks('results', options)) do
      for _, row in ipairs(block.rows) do
        found = found or row.left == '<F5>'
      end
    end
    eq(found, true)
  end)
end)

--- The word LOCKED is identical on every engine, so the sentence next to it must not be. On the
--- five strong engines the SERVER refuses the write; on mssql it does not, and telling the user it
--- does is the one overclaim the whole best-effort framing exists to prevent.
describe('app: what LOCKED is said to mean depends on the engine', function()
  local function lock_message(session_mod, spec)
    local app = require('dblens.app')
    require('dblens.config').setup(scratch_options())
    app.open()
    local state = app.state()
    assert(state, 'app.open left no state')
    state.session = h.fake_session(session_mod, spec)
    local said = {}
    local notify = vim.notify
    vim.notify = function(message)
      said[#said + 1] = message
    end
    local ok, err = pcall(app.set_locked, true)
    vim.notify = notify
    app.close()
    assert(ok, tostring(err))
    return table.concat(said, '\n')
  end

  it('credits the server on a strong engine', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local said = lock_message(session_mod, { kind = 'sqlite', path = '/tmp/dblens-test.db' })
      eq(said:find('the server refuses every write', 1, true) ~= nil, true, {
        fail_reason = 'a strong engine must still say the server refuses the write: ' .. said,
      })
    end)
  end)

  it('does not credit the server on mssql, and points at the hard boundary', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local said = lock_message(session_mod, { kind = 'mssql', database = 'app' })
      eq(said:find('the server refuses every write', 1, true), nil, {
        fail_reason = 'mssql must never claim the server refuses the write: ' .. said,
      })
      eq(said:find('dblens refuses the writes it recognises', 1, true) ~= nil, true, {
        fail_reason = 'mssql must say who is actually refusing: ' .. said,
      })
      eq(said:find('dblens%-safety%-mssql') ~= nil, true, {
        fail_reason = 'mssql must point at the read-only-login section: ' .. said,
      })
    end)
  end)
end)
