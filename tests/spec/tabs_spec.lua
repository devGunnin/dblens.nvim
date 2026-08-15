--- Result tabs: several results open at once, and the guard that keeps them apart.
---
--- The property this file exists for is the race: a query started in one tab must land in THAT
--- tab, whatever the user is looking at when it finishes and whatever order two runs complete in.
--- One shared epoch could not express that, so every tab carries its own.
local h = require('helpers')
local tabs = require('dblens.tabs')

local eq = h.eq

local function options(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
    discovery = { auto = false },
  }, extra or {})
end

local function resolved(extra)
  return require('dblens.config').setup(options(extra))
end

--- Open the UI with a session attached, so queries can be fired straight away.
local function open_with_session(session_mod, extra)
  local app = require('dblens.app')
  require('dblens.config').setup(options(extra))
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  state.session = h.fake_session(session_mod, {}, options(extra))
  return app, state
end

describe('tabs: the model', function()
  it('starts with one empty tab that is the active one', function()
    local set = tabs.new(resolved())
    eq(tabs.count(set), 1)
    eq(set.active, 1)
    eq(tabs.active(set), set.list[1])
    eq(tabs.label(set.list[1]), 'empty')
  end)

  it('gives every tab its own guards, so one cannot advance another', function()
    local opts = resolved()
    local set = tabs.new(opts)
    tabs.open(set, opts, 4)
    local first, second = set.list[1], set.list[2]
    -- Identity, not value: two fresh tabs hold equal data and must still be different objects.
    eq(rawequal(first, second), false, { fail_reason = 'the second tab reused the first' })
    first.fetch = first.fetch + 3
    first.epoch = first.epoch + 2
    eq(second.fetch, 0, { fail_reason = 'the tabs share a fetch counter' })
    eq(second.epoch, 0, { fail_reason = 'the tabs share an epoch' })
  end)

  it('refuses to open past the cap rather than growing without bound', function()
    local opts = resolved()
    local set = tabs.new(opts)
    for _ = 2, 3 do
      eq(select(1, tabs.open(set, opts, 3)) ~= nil, true)
    end
    local index, err = tabs.open(set, opts, 3)
    eq(index, nil)
    eq(type(err) == 'string' and err:find('max_tabs', 1, true) ~= nil, true, { fail_reason = err })
    eq(tabs.count(set), 3)
  end)

  it('steps and wraps in both directions', function()
    local opts = resolved()
    local set = tabs.new(opts)
    tabs.open(set, opts, 5)
    tabs.open(set, opts, 5)
    eq(set.active, 3)
    eq(tabs.step(set, 1), 1)
    eq(tabs.step(set, -1), 3)
  end)

  it('empties the last tab instead of leaving no tab at all', function()
    local opts = resolved()
    local set = tabs.new(opts)
    set.list[1].source = { kind = 'query', label = 'q' }
    eq(tabs.close(set, opts), false)
    eq(tabs.count(set), 1)
    eq(set.list[1].source, nil, { fail_reason = 'closing the last tab must clear it' })
  end)

  it('removes a tab and keeps the active index inside the list', function()
    local opts = resolved()
    local set = tabs.new(opts)
    tabs.open(set, opts, 5)
    tabs.open(set, opts, 5)
    eq(set.active, 3)
    eq(tabs.close(set, opts), true)
    eq(tabs.count(set), 2)
    eq(set.active, 2)
  end)

  it('reports a tab by what it is showing', function()
    local opts = resolved()
    local set = tabs.new(opts)
    set.list[1].source = { kind = 'relation', relation = { name = 'orders' }, label = 'orders' }
    set.list[1].result = { columns = { 'a' }, rows = { { 1 }, { 2 } }, malformed = 0 }
    set.list[1].filter = "a = '1'"
    local described = tabs.describe(set)
    eq(#described, 1)
    eq(described[1].label, 'orders')
    eq(described[1].active, true)
    eq(
      described[1].detail:find('2 rows', 1, true) ~= nil,
      true,
      { fail_reason = described[1].detail }
    )
    eq(
      described[1].detail:find('filtered', 1, true) ~= nil,
      true,
      { fail_reason = described[1].detail }
    )
  end)

  it('refuses a tab index that does not exist', function()
    local set = tabs.new(resolved())
    eq(tabs.select(set, 2), false)
    eq(tabs.select(set, 0), false)
    eq(tabs.select(set, 1.5), false)
    eq(set.active, 1)
  end)
end)

--- The whole point of a per-tab guard. Two page fetches are held open at once and resumed in the
--- WRONG order, with the user sitting on the second tab: each tab must end up holding its own
--- rows, and nothing may be drawn into the tab that did not ask for it.
describe('tabs: two queries in flight cannot cross', function()
  local function rows_of(grid)
    local out = {}
    for _, row in ipairs(grid.result and grid.result.rows or {}) do
      out[#out + 1] = tostring(row[1])
    end
    return out
  end

  it('delivers each result to the tab that asked for it, out of order', function()
    h.with_fake_exec(function(call)
      -- Counts answer at once; the page reads are held so both can be in flight together.
      if call.stdin:find('count(*)', 1, true) then
        return { stdout = h.wire({ h.record('n'), h.record('1') }) }
      end
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      local orders = { name = 'orders', kind = 'table' }
      local users = { name = 'users', kind = 'table' }
      state.session.catalog:set_relations('', { orders, users })
      for _, relation in ipairs({ orders, users }) do
        state.session.catalog:set_part(
          relation,
          'columns',
          { { name = 'id', type = 'int', pk = 1 } }
        )
        state.session.catalog:set_part(relation, 'indexes', {})
        state.session.catalog:set_part(relation, 'constraints', {})
      end

      app.open_relation(orders)
      local first_tab = state.grid
      app.open_relation(users, { new_tab = true })
      local second_tab = state.grid
      eq(rawequal(first_tab, second_tab), false, {
        fail_reason = 'the second table reused the first tab',
      })
      eq(require('dblens.tabs').count(state.tabs), 2)

      local page_calls = {}
      for _, call in ipairs(calls) do
        if call.stdin:find('SELECT *', 1, true) then
          page_calls[#page_calls + 1] = call
        end
      end
      eq(#page_calls, 2, { fail_reason = 'both tabs must have a page read in flight' })

      -- Out of order on purpose: the SECOND tab's rows land first, while it is on screen.
      page_calls[2].resume({ stdout = h.wire({ h.record('id'), h.record('u1') }) })
      page_calls[1].resume({ stdout = h.wire({ h.record('id'), h.record('o1') }) })

      eq(rows_of(first_tab), { 'o1' }, { fail_reason = 'tab 1 does not hold its own rows' })
      eq(rows_of(second_tab), { 'u1' }, { fail_reason = 'tab 2 does not hold its own rows' })
      eq(state.grid, second_tab, { fail_reason = 'a late result switched the visible tab' })
      eq(first_tab.source.label, 'orders')
      eq(second_tab.source.label, 'users')
      app.close()
    end)
  end)

  it('lands an editor query in the tab it was started from, not the one on screen', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1', { new_tab = true })
      local query_tab = state.grid
      eq(#calls, 1)

      -- The user goes back to tab 1 while the query is still running.
      app.step_tab(-1)
      eq(rawequal(state.grid, query_tab), false, { fail_reason = 'the tab did not change' })
      local watching = state.grid
      calls[1].resume({ stdout = h.wire({ h.record('n'), h.record('7') }) })

      eq(watching.result, nil, { fail_reason = 'the query wrote into the tab being watched' })
      eq(query_tab.result ~= nil and query_tab.result.rows[1][1], '7')
      app.close()
    end)
  end)

  it('drops a superseded result inside one tab instead of drawing it', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1')
      app.run_sql('SELECT 2')
      eq(#calls, 2)
      -- The first run finishes last; its rows belong to a request this tab has moved past.
      calls[2].resume({ stdout = h.wire({ h.record('n'), h.record('second') }) })
      calls[1].resume({ stdout = h.wire({ h.record('n'), h.record('first') }) })
      eq(
        state.grid.result.rows[1][1],
        'second',
        { fail_reason = 'a stale run overwrote the newer' }
      )
      app.close()
    end)
  end)

  it("does not cancel another tab's query when a new tab starts one", function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1')
      app.run_sql('SELECT 2', { new_tab = true })
      eq(#calls, 2)
      eq(calls[1].cancelled, false, { fail_reason = "opening a tab killed the first tab's query" })
      calls[1].resume({ stdout = h.wire({ h.record('n'), h.record('a') }) })
      calls[2].resume({ stdout = h.wire({ h.record('n'), h.record('b') }) })
      eq(state.tabs.list[1].result.rows[1][1], 'a')
      eq(state.tabs.list[2].result.rows[1][1], 'b')
      app.close()
    end)
  end)
end)

describe('tabs: in the app', function()
  it('closes the tab it is showing and cancels what that tab was running', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1', { new_tab = true })
      eq(state.tabs.active, 2)
      app.close_tab()
      eq(state.tabs.active, 1)
      eq(require('dblens.tabs').count(state.tabs), 1)
      eq(calls[1].cancelled, true, { fail_reason = 'closing a tab must stop its query' })
      app.close()
    end)
  end)

  it('keeps state.grid pointing at the active tab through every move', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      for _ = 1, 3 do
        app.open_tab()
      end
      for _, move in ipairs({ 1, 1, -1, -1, -1 }) do
        app.step_tab(move)
        eq(state.grid, state.tabs.list[state.tabs.active], {
          fail_reason = 'the visible grid drifted from the active tab',
        })
      end
      app.select_tab(2)
      eq(state.grid, state.tabs.list[2])
      app.close()
    end)
  end)

  it('starts a fresh tab set when the connection changes', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      app.open_tab()
      eq(require('dblens.tabs').count(state.tabs), 2)
      -- No such connection: the reset happens only on a real one, so the tabs must survive this.
      app.connect('nope')
      eq(require('dblens.tabs').count(state.tabs), 2)
      app.close()
    end)
  end)

  it('names every open result in the winbar once there is more than one', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1', { label = 'first' })
      app.run_sql('SELECT 2', { label = 'second', new_tab = true })
      app.render()
      local winbar = vim.wo[state.layout.wins.results].winbar
      eq(winbar:find('1 first', 1, true) ~= nil, true, { fail_reason = winbar })
      eq(winbar:find('2 second', 1, true) ~= nil, true, { fail_reason = winbar })
      app.close()
    end)
  end)
end)
