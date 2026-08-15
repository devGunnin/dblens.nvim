--- Pane geometry and the empty-state panels. Both are pure, and both are where a narrow
--- terminal turns into clipped text or a negative width.
local h = require('helpers')
local empty = require('dblens.ui.empty')
local layout = require('dblens.ui.layout')

local eq, expect_error = h.eq, h.expect_error

describe('layout.sidebar_width', function()
  it('honours the configured width on a terminal with room for both', function()
    eq(layout.sidebar_width(34, 120), 34)
    eq(layout.sidebar_width(34, 100), 34)
    eq(layout.sidebar_width(50, 200), 50)
  end)

  it('yields width once the grid would get too narrow to read', function()
    eq(layout.sidebar_width(34, 80), 30)
    eq(layout.sidebar_width(34, 70), 20)
    eq(layout.sidebar_width(34, 60), 20)
  end)

  it('never overflows or goes negative, at any width', function()
    for columns = 10, 300 do
      for _, configured in ipairs({ 1, 20, 34, 80, 400 }) do
        local width = layout.sidebar_width(configured, columns)
        eq(width >= 1, true, { fail_reason = ('width %d at %d columns'):format(width, columns) })
        eq(width <= columns - 1, true, {
          fail_reason = ('sidebar %d leaves no main pane at %d columns'):format(width, columns),
        })
        eq(width <= configured, true, { fail_reason = 'took more than the configured width' })
      end
    end
  end)

  it('refuses a width that is not a positive number', function()
    expect_error(function()
      layout.sidebar_width(0, 80)
    end, 'sidebar_width')
    expect_error(function()
      layout.sidebar_width(34, nil)
    end, 'sidebar_width')
  end)
end)

describe('layout.results_height', function()
  it('splits the main column by the configured share', function()
    eq(layout.results_height(22, 0.55), 12)
    eq(layout.results_height(40, 0.5), 20)
    eq(layout.results_height(30, 0.9), 27)
  end)

  it('keeps a grid tall enough for a header, a rule and a row where it can', function()
    eq(layout.results_height(10, 0.1), 3)
    eq(layout.results_height(4, 0.1), 3)
  end)

  it('always leaves the editor a line, however short the terminal', function()
    for rows = 1, 60 do
      for _, share in ipairs({ 0.1, 0.55, 0.9, 0.99 }) do
        local height = layout.results_height(rows, share)
        eq(height >= 1, true, { fail_reason = ('height %d at %d rows'):format(height, rows) })
        eq(height <= math.max(1, rows - 1), true, {
          fail_reason = ('results %d of %d rows starves the editor'):format(height, rows),
        })
      end
    end
  end)

  it('refuses a share that is not a fraction', function()
    for _, share in ipairs({ 0, 1, 1.5, -0.2 }) do
      expect_error(function()
        layout.results_height(20, share)
      end, 'results_height', { fail_reason = 'accepted share ' .. tostring(share) })
    end
  end)
end)

describe('layout: an 80x24 terminal', function()
  it('leaves both panes usable', function()
    local sidebar = layout.sidebar_width(34, 80)
    local main = 80 - sidebar - 1
    eq(sidebar >= 20, true, { fail_reason = 'the tree is too narrow to show a table name' })
    eq(main >= 45, true, { fail_reason = 'the grid is too narrow to show a row' })
    -- 24 rows less the tabline and the command line.
    local results = layout.results_height(22, 0.55)
    eq(results >= 3, true)
    eq(22 - results >= 3, true, { fail_reason = 'the editor is too short to type in' })
  end)
end)

--- A failed `open` used to keep everything it had already built: `M.open` threw, the caller had
--- no layout to close, and the tabpage plus its three scratch buffers stayed for the rest of the
--- session. Every retry added another set, and `:DbLensClose` reported success without touching
--- any of them.
describe('layout.open: the failure path owns what it built', function()
  local function dblens_buffers()
    local count = 0
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_get_name(buf):find('dblens: ', 1, true)
      then
        count = count + 1
      end
    end
    return count
  end

  it('leaves no tabpage and no buffers behind, however many times it fails', function()
    local options = vim.deepcopy(require('dblens.config').defaults)
    -- The geometry refuses this width; any throw inside `open` exercises the same path.
    options.ui.sidebar.width = 0
    local tabs, bufs = #vim.api.nvim_list_tabpages(), dblens_buffers()
    for attempt = 1, 3 do
      expect_error(function()
        layout.open(options)
      end, 'sidebar_width')
      eq(#vim.api.nvim_list_tabpages(), tabs, {
        fail_reason = ('attempt %d stranded a tabpage'):format(attempt),
      })
      eq(dblens_buffers(), bufs, {
        fail_reason = ('attempt %d stranded scratch buffers'):format(attempt),
      })
    end
  end)
end)

describe('empty.panel', function()
  it('aligns the hint keys into one column', function()
    local lines = empty.panel('no connection', {
      { key = '<leader>dc', text = 'pick one' },
      { key = ':DbLensAdd', text = 'add one' },
    })
    local first = lines[4]:find('pick one', 1, true)
    local second = lines[5]:find('add one', 1, true)
    eq(first, second, { fail_reason = 'the description column is ragged' })
  end)

  it('marks the key and the description separately, inside the line', function()
    local lines, marks = empty.panel('heading', { { key = 'gy', text = 'yank' } })
    eq(#marks >= 3, true)
    for _, mark in ipairs(marks) do
      local line = lines[mark.line + 1]
      eq(line ~= nil, true, { fail_reason = 'a mark points past the last line' })
      eq(mark.col >= 0 and mark.end_col <= #line, true, {
        fail_reason = ('mark %d..%d runs off a %d byte line'):format(mark.col, mark.end_col, #line),
      })
      eq(mark.end_col > mark.col, true)
    end
  end)

  it('takes a heading with no hints, and a hint with no key', function()
    local lines = empty.panel('nothing here', {})
    eq(#lines, 2)
    local plain = empty.panel('failed', { { text = 'syntax error near `FROM`' } })
    eq(plain[#plain]:find('syntax error', 1, true) ~= nil, true)
  end)

  it('refuses a panel with no heading', function()
    expect_error(function()
      empty.panel('', {})
    end, 'heading')
  end)
end)
