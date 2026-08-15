--- Hiding versus closing.
---
--- `q` and the toggle HIDE: the windows go, the instance stays, and showing again is the same
--- buffers, the same session and the same results. `:DbLensClose` is the teardown, and it still
--- has to release everything.
local h = require('helpers')

local eq, neq = h.eq, h.neq

local api = vim.api

local function scratch_options(extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  return vim.tbl_deep_extend('force', {
    connections_file = base .. '/connections.json',
    history_file = base .. '/history.json',
    state_file = base .. '/session.json',
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

local function dblens_buffers()
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf):find('dblens: ', 1, true) then
      out[#out + 1] = buf
    end
  end
  return out
end

local function lifecycle_autocmds()
  local ok, list = pcall(api.nvim_get_autocmds, { group = 'DbLensLifecycle' })
  return ok and #list or 0
end

describe('app: hiding keeps the instance', function()
  it('takes the windows down, keeps the buffers, the session and the results', function()
    h.with_fake_exec(function()
      return { stdout = h.wire({ h.record('id'), h.record('7') }) }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT id FROM t')
      state.tree.expanded['connection'] = true
      local session, bufs = state.session, vim.deepcopy(state.layout.bufs)
      local rows = vim.deepcopy(state.grid.result.rows)
      local before = #calls

      app.hide()
      eq(app.is_open(), false, { fail_reason = 'hiding must take the UI off screen' })
      eq(app.is_hidden(), true)
      eq(app.state() ~= nil, true, { fail_reason = 'hiding threw the instance away' })
      for pane, buf in pairs(bufs) do
        eq(api.nvim_buf_is_valid(buf), true, { fail_reason = pane .. "'s buffer was deleted" })
      end

      app.open()
      eq(app.is_open(), true, { fail_reason = 'showing again did not put it back' })
      eq(app.state(), state, { fail_reason = 'showing built a second instance' })
      eq(app.state().layout.bufs, bufs, { fail_reason = 'showing made new buffers' })
      eq(app.state().session, session, { fail_reason = 'showing replaced the session' })
      eq(#calls, before, { fail_reason = 'showing reconnected' })
      eq(state.tree.expanded['connection'], true)
      eq(state.grid.result.rows, rows, { fail_reason = 'the result was lost' })
      eq(#dblens_buffers(), 3, { fail_reason = 'the UI was duplicated' })
      app.close()
    end)
  end)

  it('is what `q` and the toggle do', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app, state = open_with_session(session_mod)
      -- The pane binding, exactly as the user's `q` reaches it.
      api.nvim_set_current_win(state.layout.wins.sidebar)
      vim.cmd('normal q')
      vim.wait(200, function()
        return not app.is_open()
      end, 10)
      eq(app.is_hidden(), true, { fail_reason = '`q` did not hide' })

      app.toggle()
      eq(app.is_open(), true, { fail_reason = 'the toggle did not show it again' })
      eq(app.state(), state)
      app.toggle()
      eq(app.is_hidden(), true, { fail_reason = 'the toggle destroyed instead of hiding' })
      app.close()
    end)
  end)

  it('does not grow buffers, windows or autocommands over repeated cycles', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app = open_with_session(session_mod)
      app.hide()
      app.open()
      local buffers = #api.nvim_list_bufs()
      local windows = #api.nvim_list_wins()
      local tabs = #api.nvim_list_tabpages()
      local autocmds = lifecycle_autocmds()

      for cycle = 1, 4 do
        app.hide()
        app.open()
        eq(
          #api.nvim_list_bufs(),
          buffers,
          { fail_reason = ('cycle %d grew buffers'):format(cycle) }
        )
        eq(
          #api.nvim_list_wins(),
          windows,
          { fail_reason = ('cycle %d grew windows'):format(cycle) }
        )
        eq(#api.nvim_list_tabpages(), tabs, { fail_reason = ('cycle %d grew tabs'):format(cycle) })
        eq(lifecycle_autocmds(), autocmds, {
          fail_reason = ('cycle %d grew autocommands'):format(cycle),
        })
      end
      app.close()
    end)
  end)

  it('keeps a running query, and its rows land in the tab that asked for them', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT id FROM t')
      eq(#calls, 1)

      app.hide()
      eq(calls[1].cancelled, false, { fail_reason = 'hiding killed the client' })
      calls[1].resume({ stdout = h.wire({ h.record('id'), h.record('3') }) })
      eq(
        state.grid.result.rows,
        { { '3' } },
        { fail_reason = 'the result did not land in its tab' }
      )

      app.open()
      local shown = api.nvim_buf_get_lines(state.layout.bufs.results, 0, -1, false)
      neq(table.concat(shown, '\n'):find('3', 1, true), nil, {
        fail_reason = 'showing again did not draw the result that arrived while hidden',
      })
      app.close()
    end)
  end)
end)

describe('app: closing is the teardown', function()
  it('releases the buffers, the tab and the augroup, and the next open starts fresh', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local tabs_before = #api.nvim_list_tabpages()
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1')
      local bufs = vim.deepcopy(state.layout.bufs)

      app.hide()
      app.close()
      eq(app.state(), nil, { fail_reason = 'closing left the instance behind' })
      eq(app.is_hidden(), false)
      eq(calls[1].cancelled, true, { fail_reason = 'closing must kill the client' })
      for pane, buf in pairs(bufs) do
        eq(api.nvim_buf_is_valid(buf), false, { fail_reason = pane .. "'s buffer outlived close" })
      end
      eq(#api.nvim_list_tabpages(), tabs_before)
      eq(lifecycle_autocmds(), 0, { fail_reason = 'the lifecycle augroup outlived close' })

      require('dblens.config').setup(scratch_options())
      app.open()
      neq(app.state(), state, { fail_reason = 'reopening resurrected the closed instance' })
      eq(app.state().session, nil, { fail_reason = 'a fresh open must not carry a session' })
      app.close()
    end)
  end)

  --- A hidden instance whose buffers were wiped by hand has nothing to show again. Opening must
  --- release what it was still holding rather than building a second instance over it.
  it('starts fresh when the hidden buffers are gone, releasing the old instance', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local app, state = open_with_session(session_mod)
      app.run_sql('SELECT 1')
      app.hide()
      for _, buf in pairs(state.layout.bufs) do
        pcall(api.nvim_buf_delete, buf, { force = true })
      end

      app.open()
      eq(app.is_open(), true)
      neq(app.state(), state, { fail_reason = 'the dead instance was shown again' })
      eq(calls[1].cancelled, true, { fail_reason = 'the old instance kept its client running' })
      eq(#dblens_buffers(), 3, { fail_reason = 'the UI was duplicated' })
      app.close()
    end)
  end)

  it('closes a hidden instance without any windows to close', function()
    h.with_fake_exec(function()
      return {}
    end, function(session_mod)
      local app = open_with_session(session_mod)
      app.hide()
      eq(pcall(app.close), true)
      eq(app.state(), nil)
      eq(dblens_buffers(), {})
    end)
  end)
end)
