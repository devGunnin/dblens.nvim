--- The winbar is the whole status surface, and a narrow window cannot show all of it. What it
--- gives up matters: dropping from the right cost the LOCKED/EDIT indicator, which is the one
--- segment that tells the user whether a keystroke can write to the database.
local h = require('helpers')
local status = require('dblens.ui.status')

local eq, expect_error = h.eq, h.expect_error

local function texts(segments)
  local out = {}
  for _, segment in ipairs(segments) do
    out[#out + 1] = segment.text
  end
  return out
end

local function shown_width(segments)
  local used = 0
  for _, segment in ipairs(segments) do
    used = used + vim.fn.strdisplaywidth(segment.text)
  end
  return used
end

describe('status.lay_out', function()
  local function bar()
    return {
      { text = ' shop', hl = 'DbLensTitle', keep = true },
      { text = '/very/long/path/to/the/database/file.sqlite3', hl = 'DbLensDim' },
      { text = '10 rows' },
      { text = '12ms' },
      { text = '⊘ LOCKED', hl = 'DbLensLocked', keep = true },
    }
  end

  it('shows everything when the window is wide enough', function()
    local out = status.lay_out(bar(), 200)
    eq(h.has(texts(out), '10 rows'), true)
    eq(h.has(texts(out), '⊘ LOCKED'), true)
    eq(shown_width(out) <= 200, true)
  end)

  it('keeps the mode indicator and gives up the optional segments instead', function()
    local out = status.lay_out(bar(), 30)
    eq(h.has(texts(out), '⊘ LOCKED'), true, { fail_reason = 'the mode indicator was dropped' })
    eq(h.has(texts(out), ' shop'), true)
    eq(h.has(texts(out), '/very/long/path/to/the/database/file.sqlite3'), false)
    eq(shown_width(out) <= 30, true, { fail_reason = 'the winbar overflowed its window' })
  end)

  it('gives the optional segments up from the right, one at a time', function()
    -- 5 + 7 + 4 + 8 plus three separators is 33; 30 has room for exactly one fewer.
    local short = {
      { text = ' shop', keep = true },
      { text = '10 rows' },
      { text = '12ms' },
      { text = '⊘ LOCKED', keep = true },
    }
    local out = texts(status.lay_out(short, 30))
    eq(h.has(out, '10 rows'), true, { fail_reason = 'the row count went before the timing' })
    eq(h.has(out, '12ms'), false, { fail_reason = 'nothing was given up' })
  end)

  it('clips only once the essential segments alone still do not fit', function()
    local out = status.lay_out(bar(), 8)
    eq(shown_width(out) <= 8, true)
    eq(#out >= 1, true)
  end)

  it('drops empty segments rather than printing bare separators', function()
    local out = status.lay_out({
      { text = 'a', keep = true },
      { text = '' },
      { text = 'b', keep = true },
    }, 40)
    eq(texts(out), { 'a', ' · ', 'b' })
  end)

  it('refuses anything that is not a list of segments and a width', function()
    expect_error(function()
      status.lay_out('nope', 40)
    end, 'lay_out')
    expect_error(function()
      status.lay_out({}, nil)
    end, 'lay_out')
  end)
end)

describe('status.compose', function()
  it('escapes a percent so a table name cannot be read as a winbar format item', function()
    local composed = status.compose({ { text = '100%', hl = 'DbLensDim' } })
    eq(composed:find('100%%', 1, true) ~= nil, true)
  end)

  it('resets to the winbar group, not Normal', function()
    local composed = status.compose({ { text = 'x' } })
    eq(composed:sub(-15), '%#DbLensWinBar#')
  end)
end)

describe('status.duration', function()
  it('reads in milliseconds under a second and in seconds above it', function()
    eq(status.duration(12), '12ms')
    eq(status.duration(999), '999ms')
    eq(status.duration(1500), '1.50s')
  end)
end)
