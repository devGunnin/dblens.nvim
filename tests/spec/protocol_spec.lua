--- `dblens.protocol` decodes the control-character record format every adapter is configured to
--- emit. The fixtures below are real bytes -- \031 field, \030 record, \029 NULL -- because the
--- whole point of the format is that no value can imitate a separator.
local h = require('helpers')
local protocol = require('dblens.protocol')

local eq, expect_error = h.eq, h.expect_error
local FS, RS, NS = h.FIELD_SEP, h.RECORD_SEP, h.NULL_SENTINEL
local NULL = h.NULL

describe('protocol constants', function()
  it('uses the ASCII unit, record and group separators', function()
    eq({ protocol.FIELD_SEP, protocol.RECORD_SEP, protocol.NULL_SENTINEL }, { FS, RS, NS })
    eq({ FS:byte(), RS:byte(), NS:byte() }, { 31, 30, 29 })
  end)

  it('represents SQL NULL as vim.NIL, which is not the empty string', function()
    eq(protocol.NULL, vim.NIL)
    h.neq(protocol.NULL, '')
    h.neq(protocol.NULL, nil)
  end)
end)

describe('protocol.decode', function()
  it('reads the first record as the header', function()
    local decoded = protocol.decode(h.wire({ h.record('id', 'name'), h.record('1', 'ada') }))
    eq(decoded.columns, { 'id', 'name' })
    eq(decoded.rows, { { '1', 'ada' } })
    eq(decoded.malformed, 0)
  end)

  it('keeps NULL and the empty string distinct', function()
    local decoded = protocol.decode(h.wire({ h.record('a', 'b'), h.record(NS, '') }))
    eq(decoded.rows[1][1], NULL)
    eq(decoded.rows[1][2], '')
    h.neq(decoded.rows[1][1], decoded.rows[1][2])
    eq(protocol.tostring(decoded.rows[1][1]), protocol.tostring(decoded.rows[1][2]))
  end)

  it('does not treat a value that merely contains the sentinel as NULL', function()
    local decoded = protocol.decode(h.wire({ h.record('a'), h.record(NS .. 'x') }))
    eq(decoded.rows[1][1], NS .. 'x')
  end)

  it('drops the trailing record separator instead of yielding an empty row', function()
    local terminated = protocol.decode(h.wire({ h.record('a'), h.record('1'), h.record('2') }))
    eq(#terminated.rows, 2)
    local unterminated =
      protocol.decode(h.record('a') .. RS .. h.record('1') .. RS .. h.record('2'))
    eq(unterminated.rows, terminated.rows)
  end)

  it('preserves newlines and tabs inside a field', function()
    local value = 'line1\nline2\tafter\r\n'
    local decoded = protocol.decode(h.wire({ h.record('a', 'b'), h.record(value, 'x') }))
    eq(decoded.rows[1][1], value)
    eq(decoded.rows[1][2], 'x')
    eq(#decoded.rows, 1)
  end)

  it('returns an empty result set for zero bytes', function()
    local decoded = protocol.decode('')
    eq(decoded.columns, {})
    eq(decoded.rows, {})
    eq(decoded.malformed, 0)
  end)

  it('falls back to caller-supplied columns when the client printed nothing', function()
    local decoded = protocol.decode('', { columns = { 'id', 'name' } })
    eq(decoded.columns, { 'id', 'name' })
    eq(decoded.rows, {})
  end)

  it('does not alias the caller-supplied column list', function()
    local columns = { 'id' }
    local decoded = protocol.decode('', { columns = columns })
    decoded.columns[1] = 'mutated'
    eq(columns, { 'id' })
  end)

  it('prefers the header over caller-supplied columns when output exists', function()
    local decoded = protocol.decode(h.wire({ h.record('real') }), { columns = { 'guess' } })
    eq(decoded.columns, { 'real' })
  end)

  it('pads a short row with NULL and counts it as malformed', function()
    local decoded = protocol.decode(h.wire({ h.record('a', 'b', 'c'), h.record('1', '2') }))
    eq(decoded.columns, { 'a', 'b', 'c' })
    eq(decoded.rows, { { '1', '2', NULL } })
    eq(decoded.malformed, 1)
  end)

  it('counts every malformed row, and keeps well-formed ones clean', function()
    local decoded = protocol.decode(h.wire({
      h.record('a', 'b'),
      h.record('1'),
      h.record('2', 'ok'),
      h.record('3'),
    }))
    eq(decoded.malformed, 2)
    eq(decoded.rows, { { '1', NULL }, { '2', 'ok' }, { '3', NULL } })
  end)

  it('keeps an over-long row whole and counts it as malformed', function()
    local decoded = protocol.decode(h.wire({ h.record('a'), h.record('1', '2') }))
    eq(decoded.malformed, 1)
    eq(decoded.rows, { { '1', '2' } })
  end)

  it('treats every record as data when header is false', function()
    local decoded =
      protocol.decode(h.wire({ h.record('1', '2') }), { header = false, columns = { 'a', 'b' } })
    eq(decoded.columns, { 'a', 'b' })
    eq(decoded.rows, { { '1', '2' } })
    eq(decoded.malformed, 0)
  end)

  it('honours a custom NULL sentinel and ignores the default one', function()
    local decoded = protocol.decode(
      h.wire({ h.record('a', 'b'), h.record('NIL', NS) }),
      { null_sentinel = 'NIL' }
    )
    eq(decoded.rows[1][1], NULL)
    eq(decoded.rows[1][2], NS)
  end)

  it('renders a NULL column name as an empty header cell', function()
    local decoded = protocol.decode(h.wire({ h.record(NS, 'b') }))
    eq(decoded.columns, { '', 'b' })
  end)

  it('rejects a non-string', function()
    expect_error(function()
      protocol.decode(nil)
    end, 'expected string')
  end)
end)

describe('protocol.tostring', function()
  it('renders NULL and nil as the empty string and passes text through', function()
    eq(protocol.tostring(protocol.NULL), '')
    eq(protocol.tostring(nil), '')
    eq(protocol.tostring('x'), 'x')
    eq(protocol.tostring(''), '')
  end)

  it('rejects a cell that is neither text nor NULL', function()
    expect_error(function()
      protocol.tostring(42)
    end, 'cells are strings or NULL')
  end)
end)

describe('protocol.column_index', function()
  it('finds a column by name and reports nil for an absent one', function()
    eq(protocol.column_index({ 'id', 'name' }, 'name'), 2)
    eq(protocol.column_index({ 'id', 'name' }, 'id'), 1)
    eq(protocol.column_index({ 'id' }, 'nope'), nil)
    eq(protocol.column_index({}, 'id'), nil)
  end)

  it('returns the first of two identically named columns', function()
    eq(protocol.column_index({ 'n', 'n' }, 'n'), 1)
  end)
end)
