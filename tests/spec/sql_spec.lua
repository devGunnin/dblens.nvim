--- `dblens.sql` is the safety gate's lexer. Nearly every case here is about a destructive
--- keyword or a `;` that must NOT be seen because it sits inside a quoted or commented span,
--- or about a byte offset that must stay exact.
local h = require('helpers')
local sql = require('dblens.sql')

local eq, expect_error = h.eq, h.expect_error

--- Statements whose `DROP TABLE users` sits in a span the scanner has to blank.
local INERT = {
  { name = 'single-quoted literal', text = "SELECT 'DROP TABLE users'" },
  { name = 'doubled quote in literal', text = "SELECT 'it''s DROP TABLE users'" },
  { name = 'quoted identifier', text = 'SELECT "drop table users" FROM t' },
  { name = 'line comment', text = 'SELECT 1 -- DROP TABLE users' },
  { name = 'line comment mid script', text = 'SELECT 1 -- DROP TABLE users\nFROM t' },
  { name = 'hash comment', text = 'SELECT 1 # DROP TABLE users\nFROM t' },
  { name = 'block comment', text = '/* DROP TABLE users */ SELECT 1' },
  { name = 'nested block comment', text = '/* outer /* DROP TABLE users */ tail */ SELECT 1' },
  { name = 'dollar-quoted body', text = 'SELECT $$ DROP TABLE users $$' },
  { name = 'tagged dollar-quoted body', text = 'SELECT $fn$ DROP TABLE users $fn$' },
  { name = 'mysql backticks', text = 'SELECT `drop table users` FROM t' },
  { name = 'sqlite brackets', text = 'SELECT [drop table users] FROM t' },
}

--- Statements carrying a `;` that is not a statement boundary.
local INNER_SEMICOLON = {
  { name = 'literal', text = "SELECT ';'" },
  { name = 'quoted identifier', text = 'SELECT "a;b" FROM t' },
  { name = 'backticks', text = 'SELECT `a;b` FROM t' },
  { name = 'brackets', text = 'SELECT [a;b] FROM t' },
  { name = 'dollar quote', text = 'SELECT $$ a; b $$' },
  { name = 'tagged dollar quote', text = 'SELECT $q$ a; b $q$' },
  { name = 'line comment', text = 'SELECT 1 -- a; b' },
  { name = 'hash comment', text = 'SELECT 1 # a; b' },
  { name = 'block comment', text = 'SELECT 1 /* a; b */' },
}

--- Malformed or degenerate input the scanner must survive without hanging.
local RAGGED = {
  '',
  ' ',
  ';',
  "SELECT 'unterminated",
  'SELECT "unterminated',
  'SELECT `unterminated',
  'SELECT [unterminated',
  'SELECT $$ unterminated',
  'SELECT $tag$ unterminated',
  '/* unterminated',
  '/* outer /* inner */ unterminated',
  '--',
  '#',
  '$',
  "e'\\''",
  'SELECT\n\n\nx',
}

--- Everything above plus the ordinary statements, for the length-preservation property.
local function corpus()
  local out = {}
  for _, case in ipairs(INERT) do
    out[#out + 1] = case.text
  end
  for _, case in ipairs(INNER_SEMICOLON) do
    out[#out + 1] = case.text
  end
  for _, text in ipairs(RAGGED) do
    out[#out + 1] = text
  end
  out[#out + 1] = "UPDATE t SET a = 'x' WHERE id = 1; DELETE FROM u -- done\n"
  out[#out + 1] = string.rep('SELECT 1; ', 40)
  return out
end

describe('sql.strip', function()
  it('preserves byte length for every statement in the corpus', function()
    for _, text in ipairs(corpus()) do
      eq(#sql.strip(text), #text, { fail_reason = 'length changed for ' .. vim.inspect(text) })
    end
  end)

  it('preserves newlines exactly, in place', function()
    local text = '/* a\nb */ SELECT 1 -- c\nFROM t'
    local stripped = sql.strip(text)
    eq(#stripped, #text)
    for i = 1, #text do
      if text:sub(i, i) == '\n' then
        eq(stripped:sub(i, i), '\n', { fail_reason = 'newline lost at byte ' .. i })
      end
    end
    eq(stripped, '    \n     SELECT 1     \nFROM t')
  end)

  it('leaves code-only input untouched', function()
    eq(sql.strip('SELECT a, b FROM t WHERE id = 1'), 'SELECT a, b FROM t WHERE id = 1')
  end)

  it('blanks the destructive keyword in every quoting form', function()
    for _, case in ipairs(INERT) do
      local stripped = sql.strip(case.text):upper()
      eq(stripped:find('DROP', 1, true), nil, { fail_reason = 'DROP survived in ' .. case.name })
      eq(#stripped, #case.text, { fail_reason = 'length changed in ' .. case.name })
    end
  end)

  it('terminates on unterminated quotes and comments', function()
    for _, text in ipairs(RAGGED) do
      h.expect_no_error(function()
        eq(#sql.strip(text), #text, { fail_reason = 'length changed for ' .. vim.inspect(text) })
      end)
    end
  end)

  it('rejects a non-string', function()
    expect_error(function()
      sql.strip(nil)
    end, 'expected string')
  end)
end)

describe('sql.tokens', function()
  it('drops whitespace and comments but keeps code tokens in order', function()
    local kinds, texts = {}, {}
    for _, token in ipairs(sql.tokens('SELECT \'a\' /* c */ FROM "t" -- x')) do
      kinds[#kinds + 1] = token.type
      texts[#texts + 1] = token.text
    end
    eq(kinds, { 'word', 'string', 'word', 'ident' })
    eq(texts, { 'SELECT', "'a'", 'FROM', '"t"' })
  end)

  it('reports the decoded value of quoted spans', function()
    local tokens = sql.tokens('SELECT \'it\'\'s\' , "a""b"')
    eq(tokens[2].value, "it's")
    eq(tokens[4].value, 'a"b')
  end)
end)

describe('sql.scan', function()
  it('covers the input gaplessly, in order', function()
    local text = "SELECT 'a' -- c\nFROM t"
    local at = 1
    for _, token in ipairs(sql.scan(text)) do
      eq(token.from, at)
      eq(token.text, text:sub(token.from, token.to))
      at = token.to + 1
    end
    eq(at, #text + 1)
  end)
end)

describe('sql.split', function()
  it('returns 1-based offsets that index back into the input', function()
    local script = "SELECT 1; -- ; not a split\nDELETE FROM t WHERE a=';'; DROP TABLE x"
    local statements = sql.split(script)
    eq(#statements, 3)
    eq(statements[1].offset, 1)
    eq(statements[2].offset, 10)
    eq(statements[3].offset, 54)
    for i, statement in ipairs(statements) do
      local at = statement.offset
      eq(script:sub(at, at + #statement.sql - 1), statement.sql, { fail_reason = 'offset ' .. i })
    end
    eq(statements[3].sql, ' DROP TABLE x')
  end)

  it('does not split on a `;` inside any quoting form', function()
    for _, case in ipairs(INNER_SEMICOLON) do
      local statements = sql.split(case.text)
      eq(#statements, 1, { fail_reason = 'split inside ' .. case.name })
      eq(statements[1].sql, case.text, { fail_reason = 'text changed for ' .. case.name })
      eq(statements[1].offset, 1)
    end
  end)

  it('drops empty and whitespace-only statements', function()
    eq(sql.split(';;;'), {})
    eq(sql.split('   '), {})
    eq(sql.split(''), {})
    eq(#sql.split('SELECT 1;\n\n'), 1)
  end)

  it('keeps a trailing statement that has no terminator', function()
    local statements = sql.split('SELECT 1; SELECT 2')
    eq(#statements, 2)
    eq(statements[2].sql, ' SELECT 2')
    eq(statements[2].offset, 10)
  end)
end)

describe('sql.classify', function()
  local CASES = {
    {
      text = 'SELECT * FROM t WHERE id = 1',
      verb = 'SELECT',
      write = false,
      destructive = false,
      has_where = true,
      whole_object = false,
      target = nil,
    },
    {
      text = 'INSERT INTO public.users (a) VALUES (1)',
      verb = 'INSERT',
      write = true,
      destructive = false,
      has_where = false,
      whole_object = false,
      target = 'public.users',
    },
    {
      text = 'UPDATE t SET a = 1',
      verb = 'UPDATE',
      write = true,
      destructive = true,
      has_where = false,
      whole_object = true,
      target = 't',
    },
    {
      text = 'UPDATE app.t SET a = 1 WHERE id = 2',
      verb = 'UPDATE',
      write = true,
      destructive = true,
      has_where = true,
      whole_object = false,
      target = 'app.t',
    },
    {
      text = 'DELETE FROM t',
      verb = 'DELETE',
      write = true,
      destructive = true,
      has_where = false,
      whole_object = true,
      target = 't',
    },
    {
      text = 'DELETE FROM "my tbl" WHERE id = 1',
      verb = 'DELETE',
      write = true,
      destructive = true,
      has_where = true,
      whole_object = false,
      target = 'my tbl',
    },
    {
      text = 'DROP TABLE IF EXISTS "x y"',
      verb = 'DROP',
      write = true,
      destructive = true,
      has_where = false,
      whole_object = true,
      target = 'x y',
    },
    {
      text = 'TRUNCATE TABLE app.logs',
      verb = 'TRUNCATE',
      write = true,
      destructive = true,
      has_where = false,
      whole_object = true,
      target = 'app.logs',
    },
    {
      text = 'ALTER TABLE t ADD COLUMN c int',
      verb = 'ALTER',
      write = true,
      destructive = true,
      has_where = false,
      whole_object = true,
      target = 't',
    },
    {
      text = 'CREATE TABLE t (a int)',
      verb = 'CREATE',
      write = true,
      destructive = false,
      has_where = false,
      whole_object = false,
      target = 't',
    },
    {
      text = 'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx ON t (a)',
      verb = 'CREATE',
      write = true,
      destructive = false,
      has_where = false,
      whole_object = false,
      target = 'idx',
    },
    {
      text = 'EXPLAIN SELECT 1',
      verb = 'EXPLAIN',
      write = false,
      destructive = false,
      has_where = false,
      whole_object = false,
      target = nil,
    },
  }

  it('reports verb, write, destructive, where, blast radius and target', function()
    for _, case in ipairs(CASES) do
      local got = sql.classify(case.text)
      eq({
        verb = got.verb,
        write = got.write,
        destructive = got.destructive,
        has_where = got.has_where,
        whole_object = got.whole_object,
        target = got.target,
      }, {
        verb = case.verb,
        write = case.write,
        destructive = case.destructive,
        has_where = case.has_where,
        whole_object = case.whole_object,
        target = case.target,
      }, { fail_reason = 'classify ' .. vim.inspect(case.text) })
      eq(got.sql, case.text)
    end
  end)

  it('upper-cases the verb of a lower-case statement', function()
    eq(sql.classify('delete from t').verb, 'DELETE')
    eq(sql.classify('delete from t').destructive, true)
  end)

  it('treats a destructive keyword inside a quoted or commented span as inert', function()
    for _, case in ipairs(INERT) do
      local got = sql.classify(case.text)
      eq({ got.verb, got.write, got.destructive, got.target }, { 'SELECT', false, false, nil }, {
        fail_reason = 'keyword escaped its span: ' .. case.name,
      })
    end
  end)

  it('reports an empty verb for empty and comment-only input', function()
    for _, text in ipairs({ '', '   ', '-- just a comment', '/* only a comment */', '#\n' }) do
      local got = sql.classify(text)
      eq(got.verb, '', { fail_reason = 'expected no verb for ' .. vim.inspect(text) })
      eq(got.write, false)
      eq(got.destructive, false)
      eq(got.target, nil)
    end
  end)

  it('does not error on unterminated quotes or comments', function()
    for _, text in ipairs(RAGGED) do
      h.expect_no_error(function()
        local got = sql.classify(text)
        eq(type(got.verb), 'string')
      end)
    end
  end)

  it('marks a WHERE-less UPDATE as whole-object and a filtered one as not', function()
    eq(sql.classify('UPDATE t SET a = 1').whole_object, true)
    eq(sql.classify('UPDATE t SET a = 1 WHERE id = 1').whole_object, false)
    -- DROP cannot be narrowed even when the text happens to contain WHERE.
    eq(sql.classify('DROP VIEW v_where').whole_object, true)
  end)

  it('does not see a WHERE that lives inside a string', function()
    eq(sql.classify("UPDATE t SET a = 'WHERE id = 1'").has_where, false)
    eq(sql.classify("UPDATE t SET a = 'WHERE id = 1'").whole_object, true)
  end)
end)

describe('sql.classify_all', function()
  it('classifies each statement of a script', function()
    local got = sql.classify_all("SELECT 1; -- ; nope\nDELETE FROM t WHERE a = ';'; DROP TABLE x")
    eq(#got, 3)
    eq({ got[1].verb, got[2].verb, got[3].verb }, { 'SELECT', 'DELETE', 'DROP' })
    eq({ got[1].destructive, got[2].destructive, got[3].destructive }, { false, true, true })
    eq(got[2].has_where, true)
    eq(got[3].target, 'x')
  end)

  it('returns one verb-less statement for a comment-only script', function()
    local got = sql.classify_all('-- nothing here\n')
    eq(#got, 1)
    eq(got[1].verb, '')
    eq(got[1].write, false)
  end)

  it('returns nothing for a script of bare separators', function()
    eq(sql.classify_all(';;;'), {})
  end)
end)

describe('sql.quote_ident', function()
  it('double-quotes and escapes embedded double quotes', function()
    eq(sql.quote_ident('my "weird" tbl'), '"my ""weird"" tbl"')
    eq(sql.quote_ident('plain'), '"plain"')
  end)

  it('back-quotes and escapes embedded backticks for backtick dialects', function()
    eq(sql.quote_ident('my `weird` tbl', sql.dialects.mysql), '`my ``weird`` tbl`')
  end)

  it('rejects an empty name and a NUL byte', function()
    expect_error(function()
      sql.quote_ident('')
    end, 'non%-empty string')
    expect_error(function()
      sql.quote_ident('a\0b')
    end, 'NUL byte')
    expect_error(function()
      sql.quote_ident(nil)
    end, 'non%-empty string')
  end)
end)

describe('sql.quote_literal', function()
  it('doubles embedded single quotes', function()
    eq(sql.quote_literal("o'brien"), "'o''brien'")
    eq(sql.quote_literal(''), "''")
    eq(sql.quote_literal("''"), "''''''")
  end)

  it('escapes backslashes for dialects that honour them', function()
    eq(sql.quote_literal([[a\b'c]], sql.dialects.mysql), [['a\\b''c']])
    eq(sql.quote_literal([[a\b'c]], sql.dialects.postgres), [['a\b''c']])
  end)

  it('keeps a `;` and a comment marker inert inside the literal', function()
    local literal = sql.quote_literal('a;b -- c')
    eq(#sql.split(literal), 1)
    eq(sql.classify('SELECT ' .. sql.quote_literal('DROP TABLE t')).destructive, false)
  end)

  it('rejects a NUL byte and a non-string', function()
    expect_error(function()
      sql.quote_literal('a\0b')
    end, 'NUL byte')
    expect_error(function()
      sql.quote_literal(42)
    end, 'expected string')
  end)
end)

describe('sql.quote_qualified', function()
  it('quotes each dotted part separately', function()
    eq(sql.quote_qualified('public.my tbl'), '"public"."my tbl"')
    eq(sql.quote_qualified('a.b.c'), '"a"."b"."c"')
    eq(sql.quote_qualified('solo'), '"solo"')
    eq(sql.quote_qualified('db.tbl', sql.dialects.mysql), '`db`.`tbl`')
  end)

  it('rejects a name with no parts', function()
    expect_error(function()
      sql.quote_qualified('')
    end, 'empty name')
    expect_error(function()
      sql.quote_qualified('...')
    end, 'empty name')
  end)
end)
