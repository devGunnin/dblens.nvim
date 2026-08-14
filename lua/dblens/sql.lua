--- SQL lexing primitives shared by the safety gate, statement splitting and completion.
---
--- Pure: no vim API, no IO. One scanner produces every span of the input; `tokens()` is the
--- code-only view and `strip()` is the blank-the-opaque-spans view. Both exist so that no
--- later scan for a keyword or a `;` can be fooled by text inside a string or a comment.
local M = {}

--- The `backtick`/`bracket` flags say what the lexer must RECOGNISE; `ident_quote` says what we
--- EMIT. sqlite accepts backticks for MySQL compatibility but its own quote is the double quote.
---@class dblens.Dialect
---@field ident_quote string       -- delimiter used when quoting an identifier we write
---@field backtick boolean         -- `ident`
---@field bracket boolean          -- [ident]
---@field hash_comment boolean     -- # to end of line
---@field dollar_quote boolean     -- $tag$ ... $tag$
---@field backslash_escape boolean -- backslash escapes inside string literals

M.dialects = {
  standard = {
    ident_quote = '"',
    backtick = false,
    bracket = false,
    hash_comment = false,
    dollar_quote = false,
    backslash_escape = false,
  },
  sqlite = {
    ident_quote = '"',
    backtick = true,
    bracket = true,
    hash_comment = false,
    dollar_quote = false,
    backslash_escape = false,
  },
  postgres = {
    ident_quote = '"',
    backtick = false,
    bracket = false,
    hash_comment = false,
    dollar_quote = true,
    backslash_escape = false,
  },
  mysql = {
    ident_quote = '`',
    backtick = true,
    bracket = false,
    hash_comment = true,
    dollar_quote = false,
    backslash_escape = true,
  },
}

--- Widest dialect, used when no connection context is known. Accepting every quoting form can
--- only blank MORE text, which fails safe for keyword scanning.
M.dialects.permissive = {
  ident_quote = '"',
  backtick = true,
  bracket = true,
  hash_comment = true,
  dollar_quote = true,
  backslash_escape = true,
}

---@class dblens.Token
---@field type 'space'|'comment'|'string'|'ident'|'word'|'number'|'punct'
---@field text string   -- exact source text
---@field from integer  -- 1-based inclusive byte offset
---@field to integer    -- 1-based inclusive byte offset
---@field value string? -- unquoted name for `ident`, decoded body for `string`

local function find_eol(sql, i)
  return (sql:find('\n', i, true) or #sql + 1) - 1
end

--- Block comments nest in postgres. Treating them as nesting elsewhere only over-consumes
--- input that is already malformed for those dialects.
local function find_block_comment_end(sql, i)
  local depth, j = 0, i
  while j <= #sql do
    local two = sql:sub(j, j + 1)
    if two == '/*' then
      depth, j = depth + 1, j + 2
    elseif two == '*/' then
      depth, j = depth - 1, j + 2
      if depth == 0 then
        return j - 1
      end
    else
      j = j + 1
    end
  end
  return #sql
end

--- End offset of a quoted span opened at `i`. `doubling` allows the SQL `''` escape.
local function find_quoted_end(sql, i, closer, doubling, backslash)
  local j = i + 1
  while j <= #sql do
    local c = sql:sub(j, j)
    if backslash and c == '\\' then
      j = j + 2
    elseif c == closer then
      if doubling and sql:sub(j + 1, j + 1) == closer then
        j = j + 2
      else
        return j
      end
    else
      j = j + 1
    end
  end
  return #sql
end

local function unquote(text, closer, doubling)
  local body = text:sub(2, text:sub(-1) == closer and -2 or -1)
  return doubling and body:gsub(closer .. closer, closer) or body
end

--- Scan the one token starting at `i`. Always advances, so the caller cannot loop forever.
---@return dblens.Token
local function scan_token(sql, i, d)
  local c, two = sql:sub(i, i), sql:sub(i, i + 1)
  local function tok(kind, to, value)
    return { type = kind, text = sql:sub(i, to), from = i, to = to, value = value }
  end

  if c:match('%s') then
    return tok('space', (sql:find('%S', i) or #sql + 1) - 1)
  end
  if two == '--' or (d.hash_comment and c == '#') then
    return tok('comment', find_eol(sql, i))
  end
  if two == '/*' then
    return tok('comment', find_block_comment_end(sql, i))
  end
  if c == "'" then
    local to = find_quoted_end(sql, i, "'", true, d.backslash_escape)
    return tok('string', to, unquote(sql:sub(i, to), "'", true))
  end
  if d.dollar_quote and c == '$' then
    local tag = sql:match('^%$[%w_]*%$', i)
    if tag then
      local close = sql:find(tag, i + #tag, true)
      local to = close and (close + #tag - 1) or #sql
      return tok('string', to, sql:sub(i + #tag, (close or #sql + 1) - 1))
    end
  end
  if c == '"' then
    local to = find_quoted_end(sql, i, '"', true, false)
    return tok('ident', to, unquote(sql:sub(i, to), '"', true))
  end
  if d.backtick and c == '`' then
    local to = find_quoted_end(sql, i, '`', true, false)
    return tok('ident', to, unquote(sql:sub(i, to), '`', true))
  end
  if d.bracket and c == '[' then
    local to = find_quoted_end(sql, i, ']', false, false)
    return tok('ident', to, unquote(sql:sub(i, to), ']', false))
  end
  if c:match('[%a_]') then
    local _, to = sql:find('^[%w_]+', i)
    return tok('word', to)
  end
  if c:match('%d') then
    local _, to = sql:find('^%d+%.?%d*', i)
    return tok('number', to)
  end
  return tok('punct', i)
end

--- Every span of the input, in order and gapless.
---@return dblens.Token[]
function M.scan(sql, dialect)
  assert(type(sql) == 'string', 'sql.scan: expected string')
  local d = dialect or M.dialects.permissive
  local out, i = {}, 1
  while i <= #sql do
    local t = scan_token(sql, i, d)
    assert(t.to >= t.from, 'sql.scan: token must advance')
    out[#out + 1] = t
    i = t.to + 1
  end
  return out
end

--- Code tokens only: whitespace and comments removed.
---@return dblens.Token[]
function M.tokens(sql, dialect)
  local out = {}
  for _, t in ipairs(M.scan(sql, dialect)) do
    if t.type ~= 'space' and t.type ~= 'comment' then
      out[#out + 1] = t
    end
  end
  return out
end

--- Blank comments and quoted spans, preserving byte offsets and newlines.
function M.strip(sql, dialect)
  local parts = {}
  for _, t in ipairs(M.scan(sql, dialect)) do
    if t.type == 'comment' or t.type == 'string' or t.type == 'ident' then
      parts[#parts + 1] = t.text:gsub('[^\n]', ' ')
    else
      parts[#parts + 1] = t.text
    end
  end
  local stripped = table.concat(parts)
  assert(#stripped == #sql, 'sql.strip: length must be preserved')
  return stripped
end

--- Split into statements at top-level `;`.
---@return { sql: string, offset: integer }[] statement text with its 1-based byte offset
function M.split(sql, dialect)
  local out, from = {}, 1
  local function push(to)
    local text = sql:sub(from, to)
    if text:match('%S') then
      out[#out + 1] = { sql = text, offset = from }
    end
  end
  for _, t in ipairs(M.scan(sql, dialect)) do
    if t.type == 'punct' and t.text == ';' then
      push(t.from - 1)
      from = t.to + 1
    end
  end
  push(#sql)
  return out
end

-- verb -> { write, destructive }. Verbs absent from this table are treated as read-only.
local VERBS = {
  SELECT = {},
  WITH = {},
  VALUES = {},
  SHOW = {},
  EXPLAIN = {},
  PRAGMA = {},
  DESCRIBE = {},
  DESC = {},
  INSERT = { write = true },
  CREATE = { write = true },
  COMMENT = { write = true },
  ANALYZE = { write = true },
  VACUUM = { write = true },
  REINDEX = { write = true },
  ATTACH = { write = true },
  DETACH = { write = true },
  UPDATE = { write = true, destructive = true },
  DELETE = { write = true, destructive = true },
  REPLACE = { write = true, destructive = true },
  MERGE = { write = true, destructive = true },
  DROP = { write = true, destructive = true },
  TRUNCATE = { write = true, destructive = true },
  ALTER = { write = true, destructive = true },
  RENAME = { write = true, destructive = true },
  GRANT = { write = true, destructive = true },
  REVOKE = { write = true, destructive = true },
}

--- Destructive verbs whose blast radius is a whole object, so a WHERE cannot narrow them.
local WHOLE_OBJECT = { DROP = true, TRUNCATE = true, ALTER = true, RENAME = true }

--- Noise between a DDL verb and the object it names.
local DDL_QUALIFIER = {
  TABLE = true,
  VIEW = true,
  INDEX = true,
  TRIGGER = true,
  SEQUENCE = true,
  SCHEMA = true,
  DATABASE = true,
  MATERIALIZED = true,
  TEMP = true,
  TEMPORARY = true,
  UNIQUE = true,
  IF = true,
  EXISTS = true,
  NOT = true,
  ONLY = true,
  CONCURRENTLY = true,
}

local function token_name(t)
  return t.type == 'ident' and t.value or t.text
end

--- Read a possibly dotted, possibly quoted object name starting at token index `i`.
local function read_qualified_name(toks, i)
  local t = toks[i]
  if not t or (t.type ~= 'word' and t.type ~= 'ident') then
    return nil
  end
  local parts = { token_name(t) }
  local j = i + 1
  while toks[j] and toks[j].type == 'punct' and toks[j].text == '.' do
    local nxt = toks[j + 1]
    if not nxt or (nxt.type ~= 'word' and nxt.type ~= 'ident') then
      break
    end
    parts[#parts + 1] = token_name(nxt)
    j = j + 2
  end
  return table.concat(parts, '.')
end

--- Locate the object a write statement targets.
local function find_target(toks, verb)
  local anchor = ({
    INSERT = 'INTO',
    DELETE = 'FROM',
    UPDATE = 'UPDATE',
    MERGE = 'INTO',
    REPLACE = 'INTO',
  })[verb]
  local skip_qualifiers = anchor == nil
  local start
  if anchor then
    for i, t in ipairs(toks) do
      if t.type == 'word' and t.text:upper() == anchor then
        start = i + 1
        break
      end
    end
  else
    start = 2
  end
  if not start then
    return nil
  end
  while
    skip_qualifiers
    and toks[start]
    and toks[start].type == 'word'
    and DDL_QUALIFIER[toks[start].text:upper()]
  do
    start = start + 1
  end
  return read_qualified_name(toks, start)
end

---@class dblens.Statement
---@field sql string
---@field verb string          -- upper-cased leading keyword, '' when the statement has none
---@field write boolean        -- mutates data or schema
---@field destructive boolean  -- must pass the confirmation gate
---@field has_where boolean
---@field whole_object boolean -- destructive with no way to narrow the blast radius
---@field target string?       -- object name, unquoted

--- Classify one statement for the safety gate.
---@return dblens.Statement
function M.classify(sql, dialect)
  local toks = M.tokens(sql, dialect)
  local first = toks[1]
  local verb = (first and first.type == 'word') and first.text:upper() or ''
  local info = VERBS[verb] or {}
  local has_where = false
  for _, t in ipairs(toks) do
    if t.type == 'word' and t.text:upper() == 'WHERE' then
      has_where = true
      break
    end
  end
  local destructive = info.destructive == true
  return {
    sql = sql,
    verb = verb,
    write = info.write == true,
    destructive = destructive,
    has_where = has_where,
    whole_object = destructive and (WHOLE_OBJECT[verb] == true or not has_where),
    target = info.write and find_target(toks, verb) or nil,
  }
end

--- Whether a bare word is a verb that writes. Used to vet fragments, like a filter predicate,
--- where there is no leading verb to classify.
---@param word string
---@return boolean
function M.is_write_verb(word)
  local info = VERBS[tostring(word):upper()]
  return info ~= nil and info.write == true
end

--- Classify every statement in a script.
---@return dblens.Statement[]
function M.classify_all(sql, dialect)
  local out = {}
  for _, st in ipairs(M.split(sql, dialect)) do
    out[#out + 1] = M.classify(st.sql, dialect)
  end
  return out
end

--- Quote a string as a SQL literal. Rejects NUL, which no CLI client can carry in argv.
function M.quote_literal(value, dialect)
  assert(type(value) == 'string', 'sql.quote_literal: expected string')
  assert(not value:find('%z'), 'sql.quote_literal: NUL byte cannot be represented')
  local d = dialect or M.dialects.standard
  local body = value:gsub("'", "''")
  if d.backslash_escape then
    body = value:gsub('\\', '\\\\'):gsub("'", "''")
  end
  return "'" .. body .. "'"
end

--- Quote an identifier. Doubling the closing delimiter is correct for every dialect we target.
function M.quote_ident(name, dialect)
  assert(type(name) == 'string' and name ~= '', 'sql.quote_ident: expected non-empty string')
  assert(not name:find('%z'), 'sql.quote_ident: NUL byte cannot be represented')
  local quote = (dialect or M.dialects.standard).ident_quote or '"'
  return quote .. name:gsub(quote, quote .. quote) .. quote
end

--- Quote a dotted name, one part at a time: `public.my tbl` -> `"public"."my tbl"`.
function M.quote_qualified(name, dialect)
  local parts = {}
  for part in tostring(name):gmatch('[^%.]+') do
    parts[#parts + 1] = M.quote_ident(part, dialect)
  end
  assert(#parts > 0, 'sql.quote_qualified: empty name')
  return table.concat(parts, '.')
end

return M
