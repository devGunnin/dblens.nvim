--- `dblens.config` merges user options over the defaults and refuses anything it does not
--- recognise: a silently ignored typo in `setup{}` is a hidden failure.
local h = require('helpers')
local config = require('dblens.config')

local eq, expect_error = h.eq, h.expect_error

describe('config.get', function()
  before_each(function()
    config.setup({})
  end)

  it('works with no setup call at all', function()
    local options = h.fresh_module('dblens.config').get()
    eq(options.page_size, 100)
    eq(options.ui.sidebar.position, 'left')
    eq(options.safety.confirm_destructive, true)
    eq(type(options.connections_file), 'string')
  end)

  it('returns the options the last setup resolved', function()
    config.setup({ page_size = 7 })
    eq(config.get().page_size, 7)
    config.setup({})
    eq(config.get().page_size, 100)
  end)

  it('fills the file paths from stdpath', function()
    local options = config.get()
    eq(type(options.connections_file), 'string')
    eq(type(options.history_file), 'string')
    eq(type(options.state_file), 'string')
    eq(options.connections_file:sub(-17), '/connections.json')
  end)
end)

--- `get()` falls back to defaults whatever went wrong, so without `status()` a REFUSED config and
--- a never-configured one are the same table. `:checkhealth` reported "OK configuration loaded"
--- to a user whose own `setup{}` had just been rejected and none of whose settings were in force.
describe('config.status', function()
  it('tells a rejected setup from a missing one and from a good one', function()
    local fresh = h.fresh_module('dblens.config')
    local state, rejected = fresh.status()
    eq(state, 'defaults')
    eq(rejected, nil)

    expect_error(function()
      fresh.setup({ page_size = 0 })
    end, 'positive integer')
    state, rejected = fresh.status()
    eq(state, 'defaults', { fail_reason = 'a refused setup must not read as configured' })
    eq(type(rejected), 'string')
    eq(fresh.get().page_size, 100, { fail_reason = 'defaults are what is actually in force' })

    fresh.setup({ page_size = 7 })
    state, rejected = fresh.status()
    eq(state, 'configured')
    eq(rejected, nil)
  end)

  it('reports the previous options as in force when a later setup is refused', function()
    local fresh = h.fresh_module('dblens.config')
    fresh.setup({ page_size = 7 })
    expect_error(function()
      fresh.setup({ page_size = 0 })
    end, 'positive integer')
    local state, rejected = fresh.status()
    eq(state, 'configured')
    eq(type(rejected), 'string')
    eq(fresh.get().page_size, 7)
  end)
end)

describe('config.setup unknown keys', function()
  it('names the offending key at the top level', function()
    expect_error(function()
      config.setup({ page_sizes = 10 })
    end, 'unknown option `page_sizes`')
  end)

  it('names the full dotted path of a nested key', function()
    expect_error(function()
      config.setup({ ui = { bogus = 1 } })
    end, 'unknown option `ui%.bogus`')
    expect_error(function()
      config.setup({ ui = { sidebar = { widht = 3 } } })
    end, 'unknown option `ui%.sidebar%.widht`')
    expect_error(function()
      config.setup({ safety = { confirm_destrutive = true } })
    end, 'unknown option `safety%.confirm_destrutive`')
    expect_error(function()
      config.setup({ keymaps = { nope = {} } })
    end, 'unknown option `keymaps%.nope`')
  end)

  it('rejects a non-table argument', function()
    expect_error(function()
      config.setup('nope')
    end, 'expected a table')
  end)
end)

describe('config.setup type checking', function()
  it('rejects a value of the wrong type, naming the expected one', function()
    expect_error(function()
      config.setup({ page_size = 'ten' })
    end, 'option `page_size` expects number, got string')
    expect_error(function()
      config.setup({ ui = { border = 7 } })
    end, 'option `ui%.border` expects string, got number')
    expect_error(function()
      config.setup({ safety = true })
    end, 'option `safety` expects table, got boolean')
  end)

  it('accepts every valid ui.icons value and names the choices when rejecting', function()
    eq(config.setup({ ui = { icons = true } }).ui.icons, true)
    eq(config.setup({ ui = { icons = false } }).ui.icons, false)
    eq(config.setup({ ui = { icons = 'nerd' } }).ui.icons, 'nerd')
    expect_error(function()
      config.setup({ ui = { icons = 'yes' } })
    end, "option `ui%.icons` must be true, false or 'nerd'")
  end)
end)

describe('config.setup derived paths', function()
  local DERIVED = { 'connections_file', 'history_file', 'state_file' }

  it('accepts an explicit path for every file option', function()
    for _, key in ipairs(DERIVED) do
      local options = config.setup({ [key] = '/custom/' .. key .. '.json' })
      eq(options[key], '/custom/' .. key .. '.json', { fail_reason = 'rejected ' .. key })
    end
  end)

  it('derives the ones the user did not set', function()
    local options = config.setup({ history_file = '/custom/history.json' })
    eq(options.history_file, '/custom/history.json')
    eq(options.connections_file:sub(-17), '/connections.json')
    eq(options.state_file:sub(-13), '/session.json')
  end)

  it('rejects a path that is not a string', function()
    for _, key in ipairs(DERIVED) do
      expect_error(
        function()
          config.setup({ [key] = 5 })
        end,
        'option `' .. key .. '` expects string, got number',
        { fail_reason = 'accepted ' .. key .. ' = 5' }
      )
    end
  end)

  it('still rejects a typo that looks like one of them', function()
    expect_error(function()
      config.setup({ history_fil = '/x.json' })
    end, 'unknown option `history_fil`')
  end)
end)

describe('config.setup open subtrees', function()
  it('accepts arbitrary connection names and shapes', function()
    local options = config.setup({
      connections = {
        ['prod pg'] = { kind = 'postgres', database = 'app', whatever = { nested = true } },
        scratch = { kind = 'sqlite', path = '/tmp/x.db' },
      },
    })
    eq(options.connections['prod pg'].whatever.nested, true)
    eq(options.connections.scratch.path, '/tmp/x.db')
  end)

  it('accepts arbitrary highlight groups', function()
    local options = config.setup({ ui = { highlights = { DbLensNull = { fg = '#666' } } } })
    eq(options.ui.highlights, { DbLensNull = { fg = '#666' } })
  end)

  --- The keys inside are open; the container is not. Exempting it too let `connections = "psql"`
  --- through `setup{}` and blow up inside `ipairs` on `:DbLens`, half a session later.
  it('still type-checks the container itself', function()
    for _, opts in ipairs({
      { connections = false },
      { connections = 'psql' },
      { ui = { highlights = 'nope' } },
    }) do
      expect_error(function()
        config.setup(opts)
      end, 'expects table', { fail_reason = 'an open subtree accepted a non-table container' })
    end
  end)

  it('accepts arbitrary keymap actions in every scope', function()
    local options = config.setup({
      keymaps = {
        global = { toggle = '<leader>d' },
        sidebar = { open = '<CR>' },
        results = { yank_cell = 'Y' },
        editor = { run = '<C-CR>' },
      },
    })
    eq(options.keymaps.global.toggle, '<leader>d')
    eq(options.keymaps.results.yank_cell, 'Y')
    eq(options.keymaps.editor.run, '<C-CR>')
  end)
end)

describe('config.setup merging', function()
  it('keeps untouched defaults when a sibling is overridden', function()
    local options = config.setup({ ui = { sidebar = { width = 50 } } })
    eq(options.ui.sidebar.width, 50)
    eq(options.ui.sidebar.position, 'left')
    eq(options.ui.grid.separator, '│')
    eq(options.ui.border, 'rounded')
    eq(options.page_size, 100)
    eq(options.safety.confirm_destructive, true)
  end)

  it('replaces a list wholesale rather than merging it element-wise', function()
    local options = config.setup({ ui = { spinner = { frames = { 'a', 'b' } } } })
    eq(options.ui.spinner.frames, { 'a', 'b' })
    eq(options.ui.spinner.interval, 80)
  end)

  it('never mutates the defaults table', function()
    config.setup({ page_size = 7, ui = { sidebar = { width = 99 } } })
    eq(config.defaults.page_size, 100)
    eq(config.defaults.ui.sidebar.width, 34)
    eq(config.defaults.connections, {})
  end)

  it('does not leak state between two setup calls', function()
    config.setup({
      page_size = 7,
      ui = { sidebar = { width = 99 }, highlights = { X = { fg = '#fff' } } },
      connections = { a = { kind = 'sqlite' } },
      keymaps = { results = { yank_cell = 'Y' } },
    })
    local fresh = config.setup({})
    eq(fresh.page_size, 100)
    eq(fresh.ui.sidebar.width, 34)
    eq(fresh.ui.highlights, {})
    eq(fresh.connections, {})
    eq(fresh.keymaps.results, {})
  end)

  it('hands back an options table the caller cannot corrupt for the next setup', function()
    local first = config.setup({})
    first.ui.grid.separator = 'X'
    eq(config.setup({}).ui.grid.separator, '│')
  end)
end)

describe('config.setup validation', function()
  it('rejects a results height that is not strictly between 0 and 1', function()
    for _, height in ipairs({ 0, 1, 1.5, -0.2, 2 }) do
      expect_error(function()
        config.setup({ ui = { results = { height = height } } })
      end, 'ui%.results%.height', { fail_reason = 'accepted height ' .. tostring(height) })
    end
    eq(config.setup({ ui = { results = { height = 0.9 } } }).ui.results.height, 0.9)
  end)

  it('rejects a sidebar position that is not left or right', function()
    expect_error(function()
      config.setup({ ui = { sidebar = { position = 'top' } } })
    end, "must be one of 'left', 'right'")
    eq(config.setup({ ui = { sidebar = { position = 'right' } } }).ui.sidebar.position, 'right')
  end)

  it('rejects a non-positive or fractional page size', function()
    for _, size in ipairs({ 0, -1, 1.5 }) do
      expect_error(
        function()
          config.setup({ page_size = size })
        end,
        'option `page_size` must be a positive integer',
        { fail_reason = 'accepted page_size ' .. tostring(size) }
      )
    end
    eq(config.setup({ page_size = 1 }).page_size, 1)
  end)

  it('rejects non-positive caps and timeouts', function()
    for _, key in ipairs({ 'max_rows', 'max_bytes', 'timeout_ms' }) do
      expect_error(
        function()
          config.setup({ [key] = 0 })
        end,
        'option `' .. key .. '` must be a positive integer',
        { fail_reason = 'accepted ' .. key .. ' = 0' }
      )
    end
  end)

  it('rejects a column width too small to hold a truncation marker', function()
    expect_error(function()
      config.setup({ ui = { grid = { max_col_width = 3 } } })
    end, 'ui%.grid%.max_col_width')
    eq(config.setup({ ui = { grid = { max_col_width = 4 } } }).ui.grid.max_col_width, 4)
  end)

  --- THE ONE THAT TOOK THE EDITOR DOWN. `chunk_size = 0` made the highlight loop reschedule
  --- itself forever with no progress: 100% CPU, `:q` unreachable, SIGTERM ignored, SIGKILL the
  --- only way out and every unsaved buffer in the instance lost.
  it('refuses a chunk size that cannot make progress', function()
    for _, size in ipairs({ 0, -1, 1.5 }) do
      expect_error(function()
        config.setup({ ui = { grid = { chunk_size = size } } })
      end, 'ui%.grid%.chunk_size', { fail_reason = 'accepted chunk_size ' .. tostring(size) })
    end
    eq(config.setup({ ui = { grid = { chunk_size = 1 } } }).ui.grid.chunk_size, 1)
  end)

  --- Each of these was accepted by `setup{}` and then failed much later, deep inside a pane,
  --- with a traceback naming a module the user never configured.
  it('refuses the values that only break later', function()
    local BAD = {
      { { ui = { sidebar = { width = 0 } } }, 'ui%.sidebar%.width' },
      { { ui = { border = 'fancy' } }, 'ui%.border' },
      { { ui = { spinner = { frames = {} } } }, 'ui%.spinner%.frames' },
      { { ui = { spinner = { interval = 0 } } }, 'ui%.spinner%.interval' },
      { { ui = { float = { max_width = 5 } } }, 'ui%.float%.max_width' },
      { { ui = { float = { max_height = 0 } } }, 'ui%.float%.max_height' },
      { { history = { max_entries = 0 } }, 'history%.max_entries' },
      { { completion = { keyword_case = 'Upper' } }, 'completion%.keyword_case' },
    }
    for _, case in ipairs(BAD) do
      expect_error(function()
        config.setup(case[1])
      end, case[2], { fail_reason = 'accepted a value matching ' .. case[2] })
    end
    -- The documented spellings still pass.
    eq(config.setup({ ui = { border = 'single' } }).ui.border, 'single')
    eq(config.setup({ completion = { keyword_case = 'keep' } }).completion.keyword_case, 'keep')
  end)

  it('leaves the previous options in place when setup fails', function()
    config.setup({ page_size = 7 })
    expect_error(function()
      config.setup({ page_size = 0 })
    end, 'positive integer')
    eq(config.get().page_size, 7)
  end)
end)

describe('config: keymap scopes', function()
  it('accepts false as a whole-scope opt-out and binds nothing', function()
    local options = config.setup({ keymaps = { global = false } })
    eq(options.keymaps.global, false)
    eq(require('dblens.keymaps').resolve('global', options.keymaps.global), {})
  end)

  it('rejects a scope that is neither a table nor false', function()
    expect_error(function()
      config.setup({ keymaps = { results = 'x' } })
    end, 'keymaps.results')
  end)

  it('names an unknown action at setup time, not when the pane opens', function()
    expect_error(function()
      config.setup({ keymaps = { results = { nosuchaction = 'x' } } })
    end, 'nosuchaction')
  end)

  it('rejects an override that is not a key, a list of keys or false', function()
    expect_error(function()
      config.setup({ keymaps = { results = { sort = 42 } } })
    end, 'keymaps.results.sort')
  end)

  it('still accepts the documented override shapes', function()
    local options = config.setup({
      keymaps = { results = { sort = '<F2>', filter = { 'f', 'F' }, refresh = false } },
    })
    local bound = {}
    for _, entry in ipairs(require('dblens.keymaps').resolve('results', options.keymaps.results)) do
      bound[entry.spec.action] = table.concat(entry.lhs, ',')
    end
    eq(bound.sort, '<F2>')
    eq(bound.filter, 'f,F')
    eq(bound.refresh, nil)
  end)
end)
