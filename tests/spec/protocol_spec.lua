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

describe('protocol.decode_csv', function()
  --- Verbatim bytes from `psql --csv -P null=\029 -f -` against PostgreSQL 18.4, for a table
  --- holding a unit separator, a record separator, a CRLF, a bare NULL marker and a value with
  --- a quote and a comma. The control-character framing this replaced split rows 3 and 5.
  local PSQL_OUTPUT = table.concat({
    'id,v',
    '1,a',
    '2,' .. NS,
    '3,x' .. FS .. 'y',
    '4,"crlf\r\nend"',
    '5,sep' .. RS .. 'here',
    '6,' .. NS,
    '7,"q""c,comma"',
    '',
  }, '\n')

  it('keeps every row intact when a value holds the old separators', function()
    local decoded = protocol.decode_csv(PSQL_OUTPUT)
    eq(decoded.columns, { 'id', 'v' })
    eq(#decoded.rows, 7)
    eq(decoded.malformed, 0)
    eq(decoded.rows[1], { '1', 'a' })
    eq(decoded.rows[2], { '2', NULL })
    eq(decoded.rows[3], { '3', 'x' .. FS .. 'y' })
    eq(decoded.rows[4], { '4', 'crlf\r\nend' })
    eq(decoded.rows[5], { '5', 'sep' .. RS .. 'here' })
    eq(decoded.rows[7], { '7', 'q"c,comma' })
  end)

  --- `exec` reads raw bytes, so a Windows psql ends every record `\r\n`. Left on, the CR rode on
  --- the last column NAME and the last cell of every row: names then failed to match, so column
  --- types, cursor→cell lookup and CRUD's row key all silently missed.
  it('drops the CR of a CRLF record terminator, but never one inside a value', function()
    local decoded = protocol.decode_csv('a,b\r\n1,2\r\n3,"in\r\nside"\r\n')
    eq(decoded.columns, { 'a', 'b' })
    eq(decoded.rows, { { '1', '2' }, { '3', 'in\r\nside' } })
    eq(decoded.malformed, 0)
  end)

  it('reads a quoted field as text even when it equals the NULL marker', function()
    local decoded = protocol.decode_csv('a\n"' .. NS .. '"\n')
    eq(decoded.rows[1], { NS })
  end)

  it('keeps the header for a zero-row result', function()
    local decoded = protocol.decode_csv('id,v\n')
    eq(decoded.columns, { 'id', 'v' })
    eq(decoded.rows, {})
  end)

  it('falls back to the supplied columns when the client printed nothing', function()
    local decoded = protocol.decode_csv('', { columns = { 'id', 'v' } })
    eq(decoded.columns, { 'id', 'v' })
    eq(decoded.rows, {})
  end)

  it('reads an empty unquoted field as the empty string, not NULL', function()
    local decoded = protocol.decode_csv('a,b\n,x\n')
    eq(decoded.rows[1], { '', 'x' })
  end)

  it('counts a short row rather than dropping it', function()
    local decoded = protocol.decode_csv('a,b,c\n1,2\n')
    eq(decoded.rows[1], { '1', '2', NULL })
    eq(decoded.malformed, 1)
  end)

  it('survives an unterminated quote instead of losing the row', function()
    local decoded = protocol.decode_csv('a\n"open and never closed\n')
    eq(decoded.rows[1], { 'open and never closed\n' })
  end)

  it('handles an embedded newline inside a quoted field', function()
    local decoded = protocol.decode_csv('a,b\n"one\ntwo",3\n')
    eq(#decoded.rows, 1)
    eq(decoded.rows[1], { 'one\ntwo', '3' })
  end)
end)

--- Framing a stream. A chunk arrives at an arbitrary byte, so a reader that decoded each one on
--- its own would split a row down the middle; only the part that ends where a record does can be
--- decoded, and the rest waits for the next chunk.
describe('protocol: where a partial stream may be cut', function()
  it('cuts the record protocol at the last separator, and nowhere when there is none', function()
    eq(protocol.record_boundary('a' .. FS .. 'b' .. RS .. 'c'), 4)
    eq(protocol.record_boundary('a' .. FS .. 'b' .. RS), 4)
    eq(protocol.record_boundary('no record here'), 0)
    eq(protocol.record_boundary(''), 0)
  end)

  it('cuts CSV only at a newline OUTSIDE quotes, since a value may hold one', function()
    eq(protocol.csv_boundary('a,b\n1,2\n'), 8)
    eq(protocol.csv_boundary('a,b\n"one\ntwo"'), 4, { fail_reason = 'cut inside a quoted value' })
    eq(protocol.csv_boundary('a,b\n"one\ntwo",3\n'), 16)
    -- `""` is an escaped quote inside the value, not the end of it.
    eq(protocol.csv_boundary('a\n"he said ""hi\n'), 2)
    eq(protocol.csv_boundary('no newline'), 0)
  end)
end)

describe('protocol: decoding a stream as it arrives', function()
  local function feed(reader, text, size)
    local rows, err = {}, nil
    for at = 1, #text, size do
      local batch, problem = reader.push(text:sub(at, at + size - 1))
      if problem then
        err = problem
        break
      end
      vim.list_extend(rows, batch)
    end
    if not err then
      vim.list_extend(rows, (reader.finish()))
    end
    return rows, err
  end

  local WIRE = h.wire({
    h.record('id', 'name'),
    h.record('1', 'a'),
    h.record('2', 'b'),
    h.record('3', 'c'),
  })

  it('produces the same rows however the chunks fall', function()
    local whole = protocol.decode(WIRE, {})
    for _, size in ipairs({ 1, 2, 3, 5, 7, #WIRE }) do
      local reader = protocol.reader({
        decode = protocol.decode,
        boundary = protocol.record_boundary,
        max_buffer = 1024,
      })
      local rows, err = feed(reader, WIRE, size)
      eq(err, nil)
      eq(
        rows,
        whole.rows,
        { fail_reason = ('chunks of %d bytes decoded differently'):format(size) }
      )
      eq(reader.columns(), { 'id', 'name' })
    end
  end)

  it('takes the header from the wire, not from the column list it was seeded with', function()
    local reader = protocol.reader({
      decode = protocol.decode,
      boundary = protocol.record_boundary,
      columns = { 'stale', 'names' },
      max_buffer = 1024,
    })
    feed(reader, WIRE, 4)
    eq(reader.columns(), { 'id', 'name' })
  end)

  it('keeps a seeded column list when the result is empty', function()
    local reader = protocol.reader({
      decode = protocol.decode,
      boundary = protocol.record_boundary,
      columns = { 'id', 'name' },
      max_buffer = 1024,
    })
    eq(select(1, reader.finish()), {})
    eq(reader.columns(), { 'id', 'name' })
  end)

  it('decodes CSV across a chunk that lands inside a quoted newline', function()
    local text = 'a,b\n"one\ntwo",3\nx,4\n'
    local reader = protocol.reader({
      decode = protocol.decode_csv,
      boundary = protocol.csv_boundary,
      max_buffer = 1024,
    })
    local rows, err = feed(reader, text, 6)
    eq(err, nil)
    eq(rows, { { 'one\ntwo', '3' }, { 'x', '4' } })
  end)

  --- Without a boundary rule the whole output has to be held, so the cap is what stops it growing
  --- without bound. It is an ERROR, never a short result reported as a whole one.
  it('refuses to buffer past its cap rather than returning half a result', function()
    local reader = protocol.reader({ decode = protocol.decode, max_buffer = 8 })
    local rows, err = feed(reader, WIRE, 4)
    eq(rows, {})
    eq(type(err) == 'string' and err:find('outgrew', 1, true) ~= nil, true, {
      fail_reason = tostring(err),
    })
  end)

  it('decodes everything at the end when there is no boundary rule', function()
    local reader = protocol.reader({ decode = protocol.decode, max_buffer = 1024 })
    local rows, err = feed(reader, WIRE, 4)
    eq(err, nil)
    eq(rows, protocol.decode(WIRE, {}).rows)
  end)
end)
