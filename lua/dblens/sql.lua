--- SQL lexing primitives shared by the destructive-change prompt, statement splitting and
--- completion.
---
--- Pure: no vim API, no IO. One scanner produces every span of the input; `tokens()` is the
--- code-only view and `strip()` is the blank-the-opaque-spans view. Both exist so that no
--- later scan for a keyword or a `;` can be fooled by text inside a string or a comment.
---
--- Classification here is BEST-EFFORT UX: it decides whether to prompt, not whether a write is
--- allowed. What a LOCKED connection is allowed to send is decided by `single_statement_problem`
--- below, which is a byte scan rather than a lexer — precisely because this lexer and a server's
--- can disagree, and every disagreement about where a statement ENDS was a bypass.
local M = {}

--- The `backtick`/`bracket` flags say what the lexer must RECOGNISE; `ident_quote` says what we
--- EMIT. sqlite accepts backticks for MySQL compatibility but its own quote is the double quote.
---@class dblens.Dialect
---@field ident_quote string       -- delimiter used when quoting an identifier we write
---@field backtick boolean         -- `ident`
---@field bracket boolean          -- [ident]
---@field hash_comment boolean     -- # to end of line
---@field dollar_quote boolean     -- $tag$ ... $tag$
---@field backslash_escape boolean -- backslash MAY escape inside string literals
---@field nested_comment boolean   -- /* /* */ */ nests; only postgres does
---@field exec_comment boolean     -- /*! ... */ is executed, so its body is code
---@field named_commands boolean   -- a bare leading `system`/`source` is a client command
---@field dash_comment_needs_space boolean -- `--` opens a comment only when whitespace follows

M.dialects = {
  standard = {
    ident_quote = '"',
    backtick = false,
    bracket = false,
    hash_comment = false,
    dollar_quote = false,
    backslash_escape = false,
    nested_comment = false,
    exec_comment = false,
    named_commands = false,
    dash_comment_needs_space = false,
  },
  sqlite = {
    ident_quote = '"',
    backtick = true,
    bracket = true,
    hash_comment = false,
    dollar_quote = false,
    backslash_escape = false,
    nested_comment = false,
    exec_comment = false,
    named_commands = false,
    dash_comment_needs_space = false,
  },
  postgres = {
    ident_quote = '"',
    backtick = false,
    bracket = false,
    hash_comment = false,
    dollar_quote = true,
    backslash_escape = false,
    nested_comment = true,
    exec_comment = false,
    named_commands = false,
    dash_comment_needs_space = false,
  },
  mysql = {
    ident_quote = '`',
    backtick = true,
    bracket = false,
    hash_comment = true,
    dollar_quote = false,
    backslash_escape = true,
    nested_comment = false,
    exec_comment = true,
    named_commands = true,
    dash_comment_needs_space = true,
  },
}

--- Widest dialect, used when no connection context is known.
---
--- "Widest" means the fail-safe direction on every axis, which is not the same as "all true":
--- a scanner that over-consumes hides live SQL, so nesting is OFF here (only postgres nests),
--- executable comments are ON (their body is code) and `--x` is code rather than a comment.
M.dialects.permissive = {
  ident_quote = '"',
  backtick = true,
  bracket = true,
  hash_comment = true,
  dollar_quote = true,
  backslash_escape = true,
  nested_comment = false,
  exec_comment = true,
  named_commands = true,
  dash_comment_needs_space = true,
}

---@class dblens.Token
---@field type 'space'|'comment'|'exec_comment'|'string'|'ident'|'word'|'number'|'punct'
---@field text string   -- exact source text
---@field from integer  -- 1-based inclusive byte offset
---@field to integer    -- 1-based inclusive byte offset
---@field value string? -- unquoted name for `ident`, decoded body for `string`
---@field closed boolean? -- for `string`/`ident`: false when the input ended before the delimiter

--- Bytes that end a line — and so a `--`/`#` comment — in SOME client we drive. Only `\n` is
--- universal; psql ends a comment at a bare `\r` too. The rest are here because ending a comment
--- EARLY is the fail-safe direction: it exposes hidden code instead of swallowing it.
local EOL_BYTE = '[%z\1-\8\10-\31\127]'

--- Unicode line/paragraph separators, as UTF-8. Lua patterns are byte-oriented, so these are
--- matched as plain substrings.
local EOL_SEQUENCE = {
  { name = 'U+0085', text = '\194\133' },
  { name = 'U+2028', text = '\226\128\168' },
  { name = 'U+2029', text = '\226\128\169' },
}

local function find_eol(sql, i)
  local at = sql:find(EOL_BYTE, i)
  for _, sep in ipairs(EOL_SEQUENCE) do
    local found = sql:find(sep.text, i, true)
    if found and (not at or found < at) then
      at = found
    end
  end
  return (at or #sql + 1) - 1
end

--- Names for the control bytes a user is most likely to have pasted in by accident, so the
--- refusal reads as something they can fix.
local CONTROL_NAME = {
  [0] = 'a NUL byte',
  [11] = 'a vertical tab',
  [12] = 'a form feed',
  [13] = 'a carriage return',
}

--- Why `text` is not provably EXACTLY ONE statement, whatever client reads it.
---
--- Deliberately NOT a lexer: a lexer is what four adversarial reviews defeated, because dblens's
--- and the server's disagree about where a statement ends and the gap is a bypass. This is a byte
--- scan for the only framing that can start a second top-level statement in psql, mysql or
--- sqlite3 — a `;` that is not the final character, a control byte a client may read as a line
--- break, or a Unicode line separator. Unknown framing counts as multiple.
---@param text string
---@return string? problem  -- nil when the input is provably one statement
function M.single_statement_problem(text)
  assert(type(text) == 'string', 'sql.single_statement_problem: expected string')
  -- Only space, tab and newline are trimmed: no client we drive treats one as a statement
  -- terminator, so trimming them cannot hide one. Every other framing byte stays and is reported.
  local body = text:gsub('^[ \t\n]+', ''):gsub('[ \t\n]+$', '')
  local control = body:find('[%z\1-\8\11-\31\127]')
  if control then
    local byte = body:byte(control)
    return ('%s (0x%02X), which a client may read as a line break'):format(
      CONTROL_NAME[byte] or 'a control character',
      byte
    )
  end
  for _, sep in ipairs(EOL_SEQUENCE) do
    if body:find(sep.text, 1, true) then
      return ('a Unicode line separator (%s)'):format(sep.name)
    end
  end
  local semicolon = body:find(';', 1, true)
  if semicolon and semicolon < #body then
    return 'a `;` that is not the final character, so a second statement can follow it'
  end
  return nil
end

--- End offset of the block comment opened at `i`.
---
--- Only postgres nests. Nesting where the server does not makes the lexer swallow the first
--- `*/` and every statement after it, so `SELECT 1 /* /* */ ; DROP TABLE t` looked like a
--- single read here while sqlite and mysql ran the DROP.
local function find_block_comment_end(sql, i, nested)
  if not nested then
    local close = sql:find('*/', i + 2, true)
    return close and (close + 1) or #sql
  end
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

--- Whether the `--` at `i` opens a comment.
---
--- MySQL/MariaDB need whitespace or a control byte after the second dash: `--1` is arithmetic
--- there, so reading it as a comment swallowed the rest of the line -- a stacked `; DROP TABLE`
--- included. End of input carries nothing to hide, so it stays a comment.
local function dash_opens_comment(sql, i, d)
  if not d.dash_comment_needs_space then
    return true
  end
  local after = sql:sub(i + 2, i + 2)
  return after == '' or after:match('[%s%c]') ~= nil
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
  if (two == '--' and dash_opens_comment(sql, i, d)) or (d.hash_comment and c == '#') then
    return tok('comment', find_eol(sql, i))
  end
  if two == '/*' then
    local to = find_block_comment_end(sql, i, d.nested_comment)
    -- MySQL/MariaDB RUN the body of `/*!40000 ... */` and `/*M! ... */`, so it is code, not a
    -- comment. Emitting it as its own type keeps it in the code stream and out of `strip`.
    if d.exec_comment and sql:match('^/%*M?!', i) then
      return tok('exec_comment', to)
    end
    return tok('comment', to)
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
  -- Bytes >= 0x80 continue a word: every engine we drive accepts unquoted non-ASCII identifiers,
  -- and falling through to `punct` made `SELECT größe FROM t` unprovable.
  if c:match('[%a_\128-\255]') then
    local _, to = sql:find('^[%w_\128-\255]+', i)
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
---
--- SHOW/DESCRIBE/DESC are swept too: `DESCRIBE`/`DESC` are MySQL synonyms for EXPLAIN, so their
--- tail can be a whole write statement.
local READ_VERBS = {
  SELECT = { scan = true },
  WITH = { scan = true },
  VALUES = { scan = true },
  TABLE = { scan = true },
  SHOW = { scan = true },
  DESCRIBE = { scan = true },
  DESC = { scan = true },
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

--- `EXPLAIN (ANALYZE false)` plans without running, so the option word alone does not mean the
--- statement executes.
local OPTION_OFF = { FALSE = true, OFF = true, ['0'] = true }

local function analyze_is_on(next_token)
  if not next_token then
    return true
  end
  if next_token.type ~= 'word' and next_token.type ~= 'number' then
    return true
  end
  return not OPTION_OFF[next_token.text:upper()]
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
        analyzing = analyzing or analyze_is_on(toks[i + 1])
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
      analyzing = analyzing or analyze_is_on(toks[i + 1])
    end
    i = i + 1
  end
  return i, analyzing
end

--- Punctuation a nested statement can start after: a CTE body `(`, the `)` that closes the CTE
--- list, or a statement separator.
local STATEMENT_START_AFTER = { ['('] = true, [')'] = true, [';'] = true }

--- Whether the word at `index` sits where a nested statement could begin, rather than naming
--- something.
---
--- `REPLACE`, `TRUNCATE` and `INSERT` are also standard functions in all three engines,
--- `comment` is an everyday column name, and `FOR UPDATE` is a locking clause. Flagging the bare
--- word refused every one of them, and a read tool that refuses reads is its own defect.
---
--- The head of the token stream is deliberately NOT such a place: a filter predicate starts with
--- a column name, and a statement's own leading verb is classified before this is consulted.
---@param toks dblens.Token[]
---@param index integer
---@return boolean
function M.opens_statement(toks, index)
  assert(type(index) == 'number' and index >= 1, 'sql.opens_statement: index must be positive')
  local previous = toks[index - 1]
  if not (previous and previous.type == 'punct' and STATEMENT_START_AFTER[previous.text]) then
    return false
  end
  local following = toks[index + 1]
  return not (following and following.type == 'punct' and following.text == '(')
end

--- Classify a token stream as a read, or fail closed.
---
--- Best-effort, and deliberately biased: a shape that is merely unrecognised comes back a write
--- so the confirmation prompt appears. Read-only itself is enforced by the server, so a miss
--- here costs a prompt rather than a table.
---@return { read: boolean, destructive: boolean, verb: string, explain_analyze: boolean }
local function analyse(toks, depth, d)
  assert(depth <= 2, 'sql.analyse: EXPLAIN nesting is bounded')
  assert(type(d) == 'table', 'sql.analyse: needs a dialect')
  local first = toks[1]
  if not first or first.type ~= 'word' then
    -- No leading keyword: a client dot-command, an executable comment, or something unparsed.
    return { read = false, destructive = false, verb = '', explain_analyze = false }
  end
  local verb = first.text:upper()
  local unread = { read = false, destructive = false, verb = verb, explain_analyze = false }

  local write = WRITE_VERBS[verb]
  if write then
    unread.destructive = write.destructive == true
    return unread
  end

  -- MySQL treats DESCRIBE/DESC as EXPLAIN synonyms. `DESCRIBE tbl` is a plain read; only the
  -- `... ANALYZE <stmt>` form carries a statement that runs.
  local second_is_analyze = toks[2] and toks[2].type == 'word' and toks[2].text:upper() == 'ANALYZE'
  if verb == 'EXPLAIN' or ((verb == 'DESCRIBE' or verb == 'DESC') and second_is_analyze) then
    local at, analyzing = explain_inner(toks)
    if not analyzing then
      -- A plan is not an execution: every client dblens drives plans without running.
      return { read = true, destructive = false, verb = verb, explain_analyze = false }
    end
    if depth == 2 then
      return unread
    end
    local inner = analyse(slice(toks, at), depth + 1, d)
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
  for index, t in ipairs(toks) do
    if t.type == 'word' then
      local word = t.text:upper()
      local hidden = read.scan and WRITE_VERBS[word]
      if hidden and M.opens_statement(toks, index) then
        unread.destructive = hidden.destructive == true
        return unread
      end
      if read.scan and READ_TAIL_BAN[word] then
        return unread
      end
    elseif t.type == 'punct' then
      if not M.SAFE_PUNCT[t.text] then
        return unread
      end
    elseif t.type == 'string' then
      -- Whether `\` escapes is a SERVER setting (NO_BACKSLASH_ESCAPES), so under a dialect that
      -- may escape, this lexer and the server can disagree about where the literal ends and a
      -- stacked statement becomes invisible. Same rule `common.check_predicate` already applies.
      if t.closed == false or (d.backslash_escape and t.text:find('\\', 1, true)) then
        return unread
      end
    elseif t.type == 'ident' then
      if t.closed == false then
        return unread
      end
    elseif t.type ~= 'number' then
      -- An executable comment, or any span this lexer does not model as inert.
      return unread
    end
  end
  return { read = true, destructive = false, verb = verb, explain_analyze = false }
end

--- Classify one statement, or a whole script.
---
--- Biased closed: a script that does not split into exactly one recognised read is reported as a
--- write, so a caller that only asks "is this a write?" errs towards asking the user.
---@return dblens.Statement
function M.classify(sql, dialect)
  assert(type(sql) == 'string', 'sql.classify: expected string')
  local d = dialect or M.dialects.permissive
  local toks = M.tokens(sql, d)
  local pieces = M.split(sql, d)
  if #toks == 0 or #pieces == 0 then
    -- Blank, or nothing but comments and separators: there is no statement to run.
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

  -- Per PIECE, not per input: a trailing `;` is a separator, and analysing the raw token stream
  -- made `SELECT 1;` a write because the `;` is not safe punctuation mid-statement.
  local info = analyse(M.tokens(pieces[1].sql, d), 0, d)
  if #pieces > 1 then
    -- Stacked statements: no single read covers the pair, and every part's danger still counts.
    local stacked = { read = false, destructive = false, verb = info.verb, explain_analyze = false }
    for _, piece in ipairs(pieces) do
      local part = analyse(M.tokens(piece.sql, d), 0, d)
      stacked.destructive = stacked.destructive or part.destructive
      stacked.explain_analyze = stacked.explain_analyze or part.explain_analyze
    end
    info = stacked
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

--- mysql client commands that reach the filesystem, a shell, or the lexer's own framing. They
--- run in the CLIENT, on this machine, and no server setting or client flag disables them —
--- `--skip-named-commands` still honours them at the start of a line.
local NAMED_COMMAND = {
  SYSTEM = true,
  SOURCE = true,
  TEE = true,
  PAGER = true,
  EDIT = true,
  CONNECT = true,
  DELIMITER = true,
}

--- Reject a client meta-command before it reaches a client.
---
--- These are not SQL and no connection setting covers them: `psql` runs `\!` as a shell command
--- mid-statement, `sqlite3 -batch` honours `.shell`, and `mysql` honours a bare `system` or
--- `source` at the head of a line even in batch mode. A server-side read-only connection cannot
--- stop any of them, which is why this check is unconditional.
---
--- A column genuinely named after one of these can still be used by quoting it, which makes it
--- an identifier token that `strip` blanks.
---@param text string
---@param dialect dblens.Dialect?
---@return string? problem
function M.client_meta_problem(text, dialect)
  assert(type(text) == 'string', 'sql.client_meta_problem: expected string')
  local d = dialect or M.dialects.permissive
  -- sqlite3 reads dot-commands per LINE, so checking the head of the statement is not enough:
  -- a `.shell` on its own line after a comment is still a dot-command. `strip` blanks comments
  -- and quoted spans while preserving offsets, so what is left is real code.
  local stripped = M.strip(text, d)
  for line in (stripped .. '\n'):gmatch('([^\n]*)\n') do
    local dot = line:match('^%s*(%.%S*)')
    if dot then
      return ('refusing `%s`: client dot-commands are not SQL'):format(dot)
    end
    local word = d.named_commands and line:match('^%s*([%a_]+)') or nil
    if word and NAMED_COMMAND[word:upper()] then
      return ('refusing `%s`: it is a client command that runs outside the database'):format(word)
    end
  end
  for _, token in ipairs(M.tokens(text, d)) do
    if token.type == 'punct' and token.text == '\\' then
      return 'refusing a `\\` meta-command: it would run outside the database'
    end
  end
  return nil
end

--- Names that reach OUTSIDE dblens's read-only transaction — a SECOND database backend, whose
--- transaction is read-write, or the server's own filesystem. A locked connection cannot prove a
--- statement calling one of these does not write: it is a single statement led by `SELECT`, so
--- the framing rule proves it is one and the transaction wrap never governs what it does.
---
--- BEST-EFFORT, AND NOT A SECURITY BOUNDARY. It matches NAMES, so a `SECURITY DEFINER` wrapper, a
--- rename or a copy in another schema walks straight through it, and nothing on this side of the
--- connection can tell the difference — only the server knows what a function does. It raises the
--- bar against a casual or accidental `SELECT dblink_exec(...)`. The hard boundary against a user
--- who has write credentials and means to use them is a database-level read-only ROLE; see
--- `:h dblens-safety-side-channel`.
---
--- sqlite is absent on purpose: `-safe` refuses `writefile()`, `.load` and ATTACH at the client,
--- and `-readonly` is the file open mode, so there is nothing here to duplicate.
local SIDE_CHANNEL = {
  {
    why = 'opens a second database session, whose transaction dblens cannot make read-only',
    prefixes = { 'DBLINK', 'POSTGRES_FDW' },
  },
  {
    why = "reaches the server's filesystem, which a read-only transaction does not govern",
    names = {
      'LO_IMPORT',
      'LO_EXPORT',
      'PG_READ_FILE',
      'PG_READ_BINARY_FILE',
      'PG_LS_DIR',
      'PG_STAT_FILE',
      'LOAD_FILE',
    },
  },
  {
    why = 'is a user-defined function that runs a command on the server',
    names = { 'SYS_EXEC', 'SYS_EVAL' },
  },
}

local SIDE_CHANNEL_NAME, SIDE_CHANNEL_PREFIX = {}, {}
for _, group in ipairs(SIDE_CHANNEL) do
  for _, name in ipairs(group.names or {}) do
    SIDE_CHANNEL_NAME[name] = group.why
  end
  for _, prefix in ipairs(group.prefixes or {}) do
    SIDE_CHANNEL_PREFIX[#SIDE_CHANNEL_PREFIX + 1] = { text = prefix, why = group.why }
  end
end

--- Why an upper-cased bare word is a known side channel, or nil.
local function side_channel_reason(word)
  local exact = SIDE_CHANNEL_NAME[word]
  if exact then
    return exact
  end
  for _, prefix in ipairs(SIDE_CHANNEL_PREFIX) do
    if word:sub(1, #prefix.text) == prefix.text then
      return prefix.why
    end
  end
  return nil
end

--- Why a LOCKED connection cannot vouch for this statement, by the name it calls.
---
--- Only UNQUOTED words are matched: a quoted identifier is a name and a string literal is data,
--- the same rule `client_meta_problem` uses, so a column called `dblink_log` stays usable when
--- quoted. A MySQL executable comment is not scanned either — it has no leading keyword, so it
--- already classifies as a write and a locked connection refuses every write.
---@param text string
---@param dialect dblens.Dialect?
---@return string? problem  -- nil when no known side channel is named
function M.side_channel_problem(text, dialect)
  assert(type(text) == 'string', 'sql.side_channel_problem: expected string')
  for _, token in ipairs(M.tokens(text, dialect or M.dialects.permissive)) do
    if token.type == 'word' then
      local why = side_channel_reason(token.text:upper())
      if why then
        return ('`%s` %s'):format(token.text, why)
      end
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
