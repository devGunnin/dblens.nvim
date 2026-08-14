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
---@field closed boolean? -- for `string`/`ident`: false when the input ended before the delimiter

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
---@return integer to, boolean closed  -- `closed` false when the input ran out first
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
        return j, true
      end
    else
      j = j + 1
    end
  end
  return #sql, false
end

local function unquote(text, closer, doubling)
  local body = text:sub(2, text:sub(-1) == closer and -2 or -1)
  return doubling and body:gsub(closer .. closer, closer) or body
end

--- Scan the one token starting at `i`. Always advances, so the caller cannot loop forever.
---@return dblens.Token
local function scan_token(sql, i, d)
  local c, two = sql:sub(i, i), sql:sub(i, i + 1)
  local function tok(kind, to, value, closed)
    return { type = kind, text = sql:sub(i, to), from = i, to = to, value = value, closed = closed }
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
    local to, closed = find_quoted_end(sql, i, "'", true, d.backslash_escape)
    return tok('string', to, unquote(sql:sub(i, to), "'", true), closed)
  end
  if d.dollar_quote and c == '$' then
    local tag = sql:match('^%$[%w_]*%$', i)
    if tag then
      local close = sql:find(tag, i + #tag, true)
      local to = close and (close + #tag - 1) or #sql
      return tok('string', to, sql:sub(i + #tag, (close or #sql + 1) - 1), close ~= nil)
    end
  end
  if c == '"' then
    local to, closed = find_quoted_end(sql, i, '"', true, false)
    return tok('ident', to, unquote(sql:sub(i, to), '"', true), closed)
  end
  if d.backtick and c == '`' then
    local to, closed = find_quoted_end(sql, i, '`', true, false)
    return tok('ident', to, unquote(sql:sub(i, to), '`', true), closed)
  end
  if d.bracket and c == '[' then
    local to, closed = find_quoted_end(sql, i, ']', false, false)
    return tok('ident', to, unquote(sql:sub(i, to), ']', false), closed)
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

-- Verbs that write. This table FLAGS a statement; it never clears one. A statement is a read
-- only when `analyse` can prove it, so a verb missing from here is still treated as a write.
local WRITE_VERBS = {
  INSERT = {},
  CREATE = {},
  COMMENT = {},
  ANALYZE = {},
  VACUUM = {},
  REINDEX = {},
  ATTACH = {},
  DETACH = {},
  COPY = {},
  DO = {},
  CALL = {},
  EXEC = {},
  EXECUTE = {},
  LOAD = {},
  IMPORT = {},
  SET = {},
  RESET = {},
  BEGIN = {},
  COMMIT = {},
  ROLLBACK = {},
  SAVEPOINT = {},
  UPDATE = { destructive = true },
  DELETE = { destructive = true },
  REPLACE = { destructive = true },
  MERGE = { destructive = true },
  DROP = { destructive = true },
  TRUNCATE = { destructive = true },
  ALTER = { destructive = true },
  RENAME = { destructive = true },
  GRANT = { destructive = true },
  REVOKE = { destructive = true },
}

--- Leading verbs that can begin a provable read. `scan` marks the ones whose tail can carry a
--- data-modifying CTE or subquery, so the whole statement has to be swept.
local READ_VERBS = {
  SELECT = { scan = true },
  WITH = { scan = true },
  VALUES = { scan = true },
  TABLE = { scan = true },
  SHOW = {},
  DESCRIBE = {},
  DESC = {},
}

--- Words that turn a SELECT into a write by redirecting its output.
local READ_TAIL_BAN = { INTO = true, OUTFILE = true, DUMPFILE = true }

--- PRAGMAs that only report. Named explicitly because the syntax gives nothing away: `PRAGMA x`
--- reads for most names but `PRAGMA optimize` runs ANALYZE and `PRAGMA wal_checkpoint` writes.
--- Introspection pragmas take an argument, so they stay reads in the `PRAGMA x(t)` call form;
--- for a getter that same form is the SET form, so it is not.
local PRAGMA_INTROSPECT = {
  TABLE_INFO = true,
  TABLE_XINFO = true,
  TABLE_LIST = true,
  INDEX_INFO = true,
  INDEX_XINFO = true,
  INDEX_LIST = true,
  FOREIGN_KEY_LIST = true,
  COLLATION_LIST = true,
  DATABASE_LIST = true,
  FUNCTION_LIST = true,
  MODULE_LIST = true,
  PRAGMA_LIST = true,
  COMPILE_OPTIONS = true,
  INTEGRITY_CHECK = true,
  QUICK_CHECK = true,
}

local PRAGMA_GETTERS = {
  USER_VERSION = true,
  APPLICATION_ID = true,
  SCHEMA_VERSION = true,
  DATA_VERSION = true,
  PAGE_SIZE = true,
  PAGE_COUNT = true,
  FREELIST_COUNT = true,
  ENCODING = true,
  JOURNAL_MODE = true,
  FOREIGN_KEYS = true,
  CACHE_SIZE = true,
  BUSY_TIMEOUT = true,
  SYNCHRONOUS = true,
}

--- Keywords that may sit between EXPLAIN and the statement it plans.
local EXPLAIN_OPTION = {
  ANALYZE = true,
  VERBOSE = true,
  QUERY = true,
  PLAN = true,
  EXTENDED = true,
  PARTITIONS = true,
  FORMAT = true,
  JSON = true,
  YAML = true,
  XML = true,
  TEXT = true,
  TREE = true,
  TRADITIONAL = true,
  COSTS = true,
  SETTINGS = true,
  BUFFERS = true,
  WAL = true,
  TIMING = true,
  SUMMARY = true,
  MEMORY = true,
  SERIALIZE = true,
  GENERIC_PLAN = true,
  ON = true,
  OFF = true,
  TRUE = true,
  FALSE = true,
}

--- Punctuation that occurs in real SQL operators. Anything else — notably `\`, which psql runs
--- as a meta-command, and `;`, which stacks a second statement — leaves a read unprovable.
M.SAFE_PUNCT = {}
for char in ('()[]{},.:=<>+-*/%|!~^&@#?$'):gmatch('.') do
  M.SAFE_PUNCT[char] = true
end

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
---@field verb string           -- upper-cased leading keyword, '' when the statement has none
---@field write boolean         -- not provably a read, so it is gated as a write
---@field destructive boolean   -- must pass the confirmation gate
---@field explain_analyze boolean -- an EXPLAIN that executes the statement it plans
---@field has_where boolean
---@field whole_object boolean  -- destructive with no way to narrow the blast radius
---@field target string?        -- object name, unquoted

local function slice(list, from)
  local out = {}
  for i = from, #list do
    out[#out + 1] = list[i]
  end
  return out
end

--- Where the statement an EXPLAIN plans begins, and whether the plan executes it.
---@return integer index, boolean analyzing
local function explain_inner(toks)
  local i, analyzing = 2, false
  if toks[i] and toks[i].type == 'punct' and toks[i].text == '(' then
    local depth = 0
    while toks[i] do
      local t = toks[i]
      if t.type == 'punct' and t.text == '(' then
        depth = depth + 1
      elseif t.type == 'punct' and t.text == ')' then
        depth = depth - 1
        if depth == 0 then
          return i + 1, analyzing
        end
      elseif t.type == 'word' and t.text:upper() == 'ANALYZE' then
        analyzing = true
      end
      i = i + 1
    end
    return i, analyzing
  end
  while toks[i] do
    local t = toks[i]
    local is_option = t.type == 'word' and EXPLAIN_OPTION[t.text:upper()]
    local is_glue = t.type == 'punct' and (t.text == '=' or t.text == ',')
    if not is_option and not is_glue then
      break
    end
    if is_option and t.text:upper() == 'ANALYZE' then
      analyzing = true
    end
    i = i + 1
  end
  return i, analyzing
end

--- Prove a token stream is a read, or fail closed.
---
--- The whole safety model rests on this being a proof and not a guess: `write` false must mean
--- "this cannot change anything", so every shape that is merely unrecognised comes back a write.
---@return { read: boolean, destructive: boolean, verb: string, explain_analyze: boolean }
local function analyse(toks, depth)
  assert(depth <= 2, 'sql.analyse: EXPLAIN nesting is bounded')
  local first = toks[1]
  if not first or first.type ~= 'word' then
    -- No leading keyword: a client dot-command, a `\` meta-command, or something unparsed.
    return { read = false, destructive = false, verb = '', explain_analyze = false }
  end
  local verb = first.text:upper()
  local unread = { read = false, destructive = false, verb = verb, explain_analyze = false }

  local write = WRITE_VERBS[verb]
  if write then
    unread.destructive = write.destructive == true
    return unread
  end

  if verb == 'EXPLAIN' then
    local at, analyzing = explain_inner(toks)
    if not analyzing then
      -- A plan is not an execution: every client dblens drives plans without running.
      return { read = true, destructive = false, verb = verb, explain_analyze = false }
    end
    if depth == 2 then
      return unread
    end
    local inner = analyse(slice(toks, at), depth + 1)
    return {
      read = inner.read,
      destructive = inner.destructive,
      verb = verb,
      explain_analyze = true,
    }
  end

  if verb == 'PRAGMA' then
    for _, t in ipairs(toks) do
      if t.type == 'punct' and t.text == '=' then
        return unread -- the set form, whatever the pragma is
      end
    end
    -- `PRAGMA main.user_version`: the name is the last word before any argument list.
    local name, called = nil, false
    for index = 2, #toks do
      local t = toks[index]
      if t.type == 'punct' and t.text == '(' then
        called = true
        break
      end
      if t.type == 'word' then
        name = t.text:upper()
      end
    end
    local reads = name ~= nil
      and (PRAGMA_INTROSPECT[name] or (not called and PRAGMA_GETTERS[name] or false))
    if not reads then
      return unread
    end
    return { read = true, destructive = false, verb = verb, explain_analyze = false }
  end

  local read = READ_VERBS[verb]
  if not read then
    return unread
  end
  for _, t in ipairs(toks) do
    if t.type == 'word' then
      local word = t.text:upper()
      local hidden = read.scan and WRITE_VERBS[word]
      if hidden then
        unread.destructive = hidden.destructive == true
        return unread
      end
      if read.scan and READ_TAIL_BAN[word] then
        return unread
      end
    elseif t.type == 'punct' and not M.SAFE_PUNCT[t.text] then
      return unread
    elseif (t.type == 'string' or t.type == 'ident') and t.closed == false then
      return unread
    end
  end
  return { read = true, destructive = false, verb = verb, explain_analyze = false }
end

--- Classify one statement, or a whole script, for the safety gate.
---
--- Fails closed by construction: a script that does not split into exactly one provably-read
--- statement is reported as a write, so a caller that only asks "is this a write?" is safe.
---@return dblens.Statement
function M.classify(sql, dialect)
  assert(type(sql) == 'string', 'sql.classify: expected string')
  local toks = M.tokens(sql, dialect)
  if #toks == 0 then
    -- Blank, or nothing but comments: there is no statement to run.
    return {
      sql = sql,
      verb = '',
      write = false,
      destructive = false,
      explain_analyze = false,
      has_where = false,
      whole_object = false,
      target = nil,
    }
  end

  local pieces = M.split(sql, dialect)
  local info = analyse(toks, 0)
  if #pieces > 1 then
    -- Stacked statements: no proof covers the pair, and every part's danger still counts.
    info = { read = false, destructive = false, verb = info.verb, explain_analyze = false }
    for _, piece in ipairs(pieces) do
      local part = analyse(M.tokens(piece.sql, dialect), 0)
      info.destructive = info.destructive or part.destructive
      info.explain_analyze = info.explain_analyze or part.explain_analyze
    end
  end

  local has_where = false
  for _, t in ipairs(toks) do
    if t.type == 'word' and t.text:upper() == 'WHERE' then
      has_where = true
      break
    end
  end
  local write = not info.read
  return {
    sql = sql,
    verb = info.verb,
    write = write,
    destructive = info.destructive,
    explain_analyze = info.explain_analyze,
    has_where = has_where,
    whole_object = info.destructive and (WHOLE_OBJECT[info.verb] == true or not has_where),
    target = write and find_target(toks, info.verb) or nil,
  }
end

--- Whether a bare word is a verb that writes. Used to vet fragments, like a filter predicate,
--- where there is no leading verb to classify.
---@param word string
---@return boolean
function M.is_write_verb(word)
  return WRITE_VERBS[tostring(word):upper()] ~= nil
end

--- Reject a client meta-command before it reaches a client.
---
--- These are not SQL and no `read_only` flag applies to them: `psql` runs `\!` as a shell
--- command mid-statement, and `sqlite3 -batch` still honours `.shell`. Neither is ever something
--- dblens legitimately sends, so the check is unconditional rather than part of the read proof.
---@param text string
---@param dialect dblens.Dialect?
---@return string? problem
function M.client_meta_problem(text, dialect)
  assert(type(text) == 'string', 'sql.client_meta_problem: expected string')
  -- sqlite3 reads dot-commands per LINE, so checking the head of the statement is not enough:
  -- a `.shell` on its own line after a comment is still a dot-command. `strip` blanks comments
  -- and quoted spans while preserving offsets, so what is left is real code.
  local stripped = M.strip(text, dialect)
  for line in (stripped .. '\n'):gmatch('([^\n]*)\n') do
    local head = line:match('^%s*(%.%S*)')
    if head then
      return ('refusing `%s`: client dot-commands are not SQL'):format(head)
    end
  end
  for _, token in ipairs(M.tokens(text, dialect)) do
    if token.type == 'punct' and token.text == '\\' then
      return 'refusing a `\\` meta-command: it would run outside the database'
    end
  end
  return nil
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
