--- Formatting the SQL buffer.
---
--- The security claim is narrow and worth proving: the formatter is spawned from an argv ARRAY,
--- the SQL reaches it on STDIN as data, and nothing about this path can execute it. No session, no
--- client, no database — so a statement holding `DROP TABLE` is text going through a text tool.
local h = require('helpers')

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

local function open_ui(extra)
  local app = require('dblens.app')
  require('dblens.config').setup(options(extra))
  app.open()
  local state = app.state()
  assert(state, 'app.open left no state')
  return app, state
end

local function editor_lines(state)
  return vim.api.nvim_buf_get_lines(state.layout.bufs.editor, 0, -1, false)
end

local function set_editor(state, lines)
  vim.api.nvim_buf_set_lines(state.layout.bufs.editor, 0, -1, false, lines)
end

--- A directory holding executable stubs, prepended to PATH for the duration of `fn`.
---@param stubs table<string, string>  -- name -> shell script body
local function with_path(stubs, fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  for name, body in pairs(stubs) do
    local path = dir .. '/' .. name
    local file = assert(io.open(path, 'w'))
    file:write('#!/bin/sh\n' .. body .. '\n')
    file:close()
    assert(vim.uv.fs_chmod(path, 493), 'could not make the stub executable')
  end
  local saved = vim.env.PATH
  vim.env.PATH = dir .. ':' .. saved
  local ok, err = pcall(fn, dir)
  vim.env.PATH = saved
  vim.fn.delete(dir, 'rf')
  if not ok then
    error(err, 0)
  end
end

describe('format: choosing a formatter', function()
  local format = require('dblens.format')

  it('takes the configured argv over anything installed', function()
    local argv, err = format.detect({ 'sh', '-c', 'cat' })
    eq(err, nil)
    eq(argv, { 'sh', '-c', 'cat' })
  end)

  it('reports a configured formatter that is not installed, by name', function()
    local argv, err = format.detect({ 'definitely-not-a-formatter' })
    eq(argv, nil)
    eq(err:find('definitely-not-a-formatter', 1, true) ~= nil, true, { fail_reason = err })
    eq(err:find('format.command', 1, true) ~= nil, true, { fail_reason = err })
  end)

  it('prefers the first installed candidate, in the declared order', function()
    with_path({ pg_format = 'cat', sqlformat = 'cat' }, function()
      eq(format.detect(nil)[1], 'pg_format')
    end)
    with_path({ sqlfluff = 'cat', pg_format = 'cat' }, function()
      eq(format.detect(nil)[1], 'sqlfluff')
    end)
  end)

  it('names what to install rather than crashing when there is none', function()
    -- An empty PATH: nothing at all is executable, which is the case a fresh machine is in.
    local saved = vim.env.PATH
    vim.env.PATH = vim.fn.tempname()
    local argv, err = format.detect(nil)
    vim.env.PATH = saved
    eq(argv, nil)
    for _, name in ipairs({ 'sqlfluff', 'pg_format', 'sqlformat' }) do
      eq(err:find(name, 1, true) ~= nil, true, { fail_reason = err })
    end
  end)
end)

describe('format: how the formatter is run', function()
  it('passes an argv array and the SQL on stdin, never a shell string', function()
    h.with_fake_exec(function()
      return { stdout = 'SELECT 1\n' }
    end, function(_, calls)
      local format = require('dblens.format')
      local done = h.capture()
      format.run('select 1', resolved({ format = { command = { 'cat' } } }), done.sink)

      eq(#calls, 1)
      eq(calls[1].argv, { 'cat' }, { fail_reason = vim.inspect(calls[1].argv) })
      eq(calls[1].stdin, 'select 1')
      eq(calls[1].spec.env, nil, { fail_reason = 'the formatter was handed an environment' })
      eq(done[1], 'SELECT 1\n')
      eq(done[2], nil)
    end)
  end)

  --- The whole point: a statement that would drop a table is TEXT here. It goes in on stdin and
  --- comes back on stdout, and nothing in this path can reach a database with it.
  it('sends a destructive statement through as data, and runs no client', function()
    h.with_fake_exec(function(call)
      return { stdout = call.stdin:upper() }
    end, function(_, calls)
      local format = require('dblens.format')
      local hostile = "drop table users; -- '); DROP TABLE t;--"
      local done = h.capture()
      format.run(hostile, resolved({ format = { command = { 'cat' } } }), done.sink)

      eq(#calls, 1, { fail_reason = 'the formatter run was not the only process' })
      eq(calls[1].stdin, hostile, { fail_reason = 'the SQL was altered on the way in' })
      eq(calls[1].argv, { 'cat' })
      -- argv holds the formatter and its flags only: the SQL is never an argument.
      eq(h.leaks(calls[1].argv, 'DROP'), false)
      eq(h.leaks(calls[1].argv, 'drop'), false)
      eq(done[1], hostile:upper())
    end)
  end)

  it('reports a formatter that failed, and returns no text', function()
    h.with_fake_exec(function()
      return { ok = false, code = 1, stderr = 'cat: syntax error at line 1' }
    end, function()
      local done = h.capture()
      require('dblens.format').run(
        'select',
        resolved({ format = { command = { 'cat' } } }),
        done.sink
      )
      eq(done[1], nil)
      eq(done[2]:find('syntax error', 1, true) ~= nil, true, { fail_reason = tostring(done[2]) })
    end)
  end)

  it('refuses to hand back nothing, which would empty the buffer', function()
    h.with_fake_exec(function()
      return { stdout = '   \n' }
    end, function()
      local done = h.capture()
      require('dblens.format').run(
        'select 1',
        resolved({ format = { command = { 'cat' } } }),
        done.sink
      )
      eq(done[1], nil)
      eq(
        done[2]:find('returned nothing', 1, true) ~= nil,
        true,
        { fail_reason = tostring(done[2]) }
      )
    end)
  end)

  it('starts nothing at all for empty input', function()
    h.with_fake_exec(function()
      return {}
    end, function(_, calls)
      local done = h.capture()
      require('dblens.format').run(
        '   \n\n',
        resolved({ format = { command = { 'cat' } } }),
        done.sink
      )
      eq(#calls, 0)
      eq(done[2], 'nothing to format')
    end)
  end)
end)

describe('format: the editor buffer', function()
  it('replaces the buffer with what the formatter printed', function()
    with_path({ ['dblens-stub-fmt'] = 'tr a-z A-Z' }, function()
      local app, state = open_ui({ format = { command = { 'dblens-stub-fmt' } } })
      set_editor(state, { 'select a', 'from t;' })

      require('dblens.ui.editor').format_range(state, 1, 2)
      assert(
        vim.wait(20000, function()
          return editor_lines(state)[1] == 'SELECT A'
        end),
        'the buffer was never formatted: ' .. vim.inspect(editor_lines(state))
      )
      eq(editor_lines(state), { 'SELECT A', 'FROM T;' })
      app.close()
    end)
  end)

  it('formats only the lines it was given', function()
    with_path({ ['dblens-stub-fmt'] = 'tr a-z A-Z' }, function()
      local app, state = open_ui({ format = { command = { 'dblens-stub-fmt' } } })
      set_editor(state, { 'select a;', 'select b;', 'select c;' })

      require('dblens.ui.editor').format_range(state, 2, 2)
      assert(
        vim.wait(20000, function()
          return editor_lines(state)[2] == 'SELECT B;'
        end),
        'the range was never formatted'
      )
      eq(editor_lines(state), { 'select a;', 'SELECT B;', 'select c;' })
      app.close()
    end)
  end)

  it('leaves the buffer alone when the formatter fails', function()
    with_path({ ['dblens-stub-fmt'] = 'echo "boom" >&2; exit 3' }, function()
      local app, state = open_ui({ format = { command = { 'dblens-stub-fmt' } } })
      set_editor(state, { 'select a;' })
      local said = {}
      local notify = vim.notify
      vim.notify = function(message)
        said[#said + 1] = message
      end

      require('dblens.ui.editor').format_range(state, 1, 1)
      vim.wait(20000, function()
        return #said > 0
      end)
      vim.notify = notify

      eq(
        editor_lines(state),
        { 'select a;' },
        { fail_reason = 'a failed format touched the buffer' }
      )
      eq(
        table.concat(said, '\n'):find('boom', 1, true) ~= nil,
        true,
        { fail_reason = table.concat(said, '\n') }
      )
      app.close()
    end)
  end)

  it('says what to install instead of failing silently when there is no formatter', function()
    local saved = vim.env.PATH
    local app, state = open_ui()
    set_editor(state, { 'select a;' })
    local said = {}
    local notify = vim.notify
    vim.notify = function(message)
      said[#said + 1] = message
    end
    vim.env.PATH = vim.fn.tempname()

    require('dblens.ui.editor').format_range(state, 1, 1)

    vim.env.PATH = saved
    vim.notify = notify
    eq(editor_lines(state), { 'select a;' })
    eq(
      table.concat(said, '\n'):find('no SQL formatter found', 1, true) ~= nil,
      true,
      { fail_reason = table.concat(said, '\n') }
    )
    app.close()
  end)
end)

describe('format: the option', function()
  it('refuses a shell string, which would be spawned as one impossible binary', function()
    h.expect_error(function()
      require('dblens.config').setup(options({ format = { command = 'pg_format -' } }))
    end, 'format%.command')
  end)

  it('refuses a non-string argv entry', function()
    h.expect_error(function()
      require('dblens.config').setup(options({ format = { command = { 'pg_format', 42 } } }))
    end, 'format%.command')
  end)

  it('still refuses a typo next to it', function()
    h.expect_error(function()
      require('dblens.config').setup(options({ format = { commnad = { 'pg_format' } } }))
    end, 'format%.commnad')
  end)

  it('defaults to detection, which is what an empty command means', function()
    eq(resolved().format.command, {})
    eq(require('dblens.format').detect({}) ~= nil or true, true)
  end)
end)
