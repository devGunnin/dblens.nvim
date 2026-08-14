--- Schema-aware SQL completion: the engine every completion surface shares.
---
--- `context`, `aliases` and `candidates` are pure — everything they need arrives as an argument —
--- so the interesting logic is unit-testable without a buffer, a plugin or a connection. Only
--- `complete_at`, `omnifunc` and `attach` touch Neovim.
---
--- All of the SQL reading goes through `dblens.sql`: a dot inside a string literal or a comment is
--- part of that token, so it can never be mistaken for a column qualifier.
local config = require('dblens.config')
local sql = require('dblens.sql')

local M = {}

---@class dblens.CompletionContext
---@field kind 'column'|'table'|'any'
---@field prefix string     -- partial word at the cursor, unquoted; '' when none is being typed
---@field qualifier string? -- the name before the dot for `column`: a relation name or an alias

---@class dblens.CompletionItem
---@field word string
---@field kind 'keyword'|'table'|'view'|'column'
---@field menu string
---@field detail string?

--- Offered by `kind = 'any'`. Stored upper-case and cased on the way out; also the set of words
--- that can never be read as a table alias. Written as text so the list stays readable.
local KEYWORDS = vim.split(
  table.concat({
    'ADD ALL ALTER ANALYZE AND ANY AS ASC ATTACH AVG',
    'BEGIN BETWEEN BY CASCADE CASE CAST CHECK COALESCE COLUMN COMMIT CONFLICT CONSTRAINT COUNT',
    'CREATE CROSS CURRENT DATABASE DEFAULT DELETE DESC DESCRIBE DETACH DISTINCT DO DROP',
    'ELSE END EXCEPT EXISTS EXPLAIN EXTRACT FALSE FETCH FOREIGN FROM FULL GRANT GROUP HAVING',
    'IF ILIKE IN INDEX INNER INSERT INTERSECT INTERVAL INTO IS JOIN KEY LATERAL LEFT LIKE LIMIT',
    'MATERIALIZED MAX MERGE MIN NATURAL NOT NOTHING NULL NULLIF OFFSET ON ONLY OR ORDER OUTER OVER',
    'PARTITION PRAGMA PRIMARY RANGE RECURSIVE REFERENCES REINDEX RENAME REPLACE RESTRICT RETURNING',
    'REVOKE RIGHT ROLLBACK ROWS SELECT SET SHOW SOME SUM TABLE TEMPORARY THEN TRIGGER TRUE TRUNCATE',
    'UNION UNIQUE UPDATE USING VACUUM VALUES VIEW WHEN WHERE WINDOW WITH',
  }, ' '),
  ' ',
  { plain = true }
)

local KEYWORD_SET = {}
for _, keyword in ipairs(KEYWORDS) do
  KEYWORD_SET[keyword] = true
end

--- A relation name is expected right after these.
local TABLE_ANCHOR = { FROM = true, JOIN = true, INTO = true, UPDATE = true, TABLE = true }

--- Clauses that declare the relations an alias can belong to.
local SOURCE_ANCHOR = { FROM = true, JOIN = true }

--- Lines of buffer read on each side of the cursor. A statement longer than this loses only the
--- aliases declared outside the window.
local MAX_CONTEXT_LINES = 200

local OMNIFUNC = "v:lua.require'dblens.completion'.omnifunc"

local function token_name(token)
  return token.type == 'ident' and (token.value or token.text) or token.text
end

--- The word being typed: the last code token, and only when it reaches the cursor.
---@return dblens.Token? token, integer index  index the typed word occupies in `toks`
local function typed_token(toks, len)
  local last = toks[#toks]
  if last and last.to == len and (last.type == 'word' or last.type == 'ident') then
    return last, #toks
  end
  return nil, #toks + 1
end

--- The `<name>` of a `<name>.` that the cursor sits behind. The dot must touch both the name and
--- the word being typed, so `a . b`, `'a.b'` and `-- a.b` cannot produce a qualifier.
---@return string?
local function qualifier_before(toks, at, word, len)
  local dot, name = toks[at - 1], toks[at - 2]
  if not (dot and dot.type == 'punct' and dot.text == '.') then
    return nil
  end
  if not (name and (name.type == 'word' or name.type == 'ident')) then
    return nil
  end
  if name.to + 1 ~= dot.from then
    return nil
  end
  local touches
  if word then
    touches = dot.to + 1 == word.from
  else
    touches = dot.to == len
  end
  if not touches then
    return nil
  end
  return token_name(name)
end

--- What the cursor is asking for.
---@param text string          text before the cursor (a statement, or a line)
---@param dialect dblens.Dialect?
---@return dblens.CompletionContext
function M.context(text, dialect)
  assert(type(text) == 'string', 'completion.context: expected a string')
  assert(dialect == nil or type(dialect) == 'table', 'completion.context: dialect must be a table')
  local toks = sql.tokens(text, dialect)
  local word, at = typed_token(toks, #text)
  local prefix = word and token_name(word) or ''
  assert(#prefix <= #text, 'completion.context: the prefix cannot be longer than its source')

  local qualifier = qualifier_before(toks, at, word, #text)
  if qualifier then
    return { kind = 'column', prefix = prefix, qualifier = qualifier }
  end
  local previous = toks[at - 1]
  if previous and previous.type == 'word' and TABLE_ANCHOR[previous.text:upper()] then
    return { kind = 'table', prefix = prefix }
  end
  return { kind = 'any', prefix = prefix }
end

--- Read a possibly dotted, possibly quoted relation name at `i`.
---@return string? name, integer next_index
local function read_name(toks, i)
  local token = toks[i]
  if not (token and (token.type == 'word' or token.type == 'ident')) then
    return nil, i
  end
  if token.type == 'word' and KEYWORD_SET[token.text:upper()] then
    return nil, i
  end
  local parts = { token_name(token) }
  local j = i + 1
  while toks[j] and toks[j].type == 'punct' and toks[j].text == '.' do
    local next_token = toks[j + 1]
    if not (next_token and (next_token.type == 'word' or next_token.type == 'ident')) then
      break
    end
    parts[#parts + 1] = token_name(next_token)
    j = j + 2
  end
  return table.concat(parts, '.'), j
end

--- Read the `name [AS] alias` items of one FROM/JOIN clause, following commas.
---@return integer next_index  never less than `i`, so the caller always makes progress
local function read_sources(toks, i, out)
  while true do
    local name, after_name = read_name(toks, i)
    if not name then
      return i
    end
    i = after_name
    if toks[i] and toks[i].type == 'word' and toks[i].text:upper() == 'AS' then
      i = i + 1
    end
    local alias = toks[i]
    local is_keyword = alias and alias.type == 'word' and KEYWORD_SET[alias.text:upper()]
    if alias and (alias.type == 'word' or alias.type == 'ident') and not is_keyword then
      out[token_name(alias)] = name
      i = i + 1
    end
    if not (toks[i] and toks[i].type == 'punct' and toks[i].text == ',') then
      return i
    end
    i = i + 1
  end
end

--- Alias -> relation name, as written, for every FROM/JOIN source in the statement.
---@param text string
---@param dialect dblens.Dialect?
---@return table<string, string>
function M.aliases(text, dialect)
  assert(type(text) == 'string', 'completion.aliases: expected a string')
  local toks = sql.tokens(text, dialect)
  local out, i = {}, 1
  while i <= #toks do
    local token = toks[i]
    if token.type == 'word' and SOURCE_ANCHOR[token.text:upper()] then
      local next_index = read_sources(toks, i + 1, out)
      assert(next_index > i, 'completion.aliases: source scan must advance')
      i = next_index
    else
      i = i + 1
    end
  end
  return out
end

--- Case-insensitive alias lookup. Ties break on the alias text, never on `pairs` order.
local function alias_target(aliases, qualifier)
  if not aliases then
    return nil
  end
  if aliases[qualifier] then
    return aliases[qualifier]
  end
  local want, best_alias, best_name = qualifier:lower(), nil, nil
  for alias, name in pairs(aliases) do
    if alias:lower() == want and (best_alias == nil or alias < best_alias) then
      best_alias, best_name = alias, name
    end
  end
  return best_name
end

--- The relation a `schema.name` or bare `name` refers to. SQL names compare case-insensitively,
--- and a name is matched whole before it is read as `schema.name`, so a dotted name still resolves.
---@return dblens.Relation?
local function find_relation(catalog, name)
  local relations = catalog:all_relations()
  local want = name:lower()
  for _, relation in ipairs(relations) do
    if relation.name:lower() == want then
      return relation
    end
  end
  local schema, bare = name:match('^(.*)%.([^%.]+)$')
  if not schema then
    return nil
  end
  for _, relation in ipairs(relations) do
    if
      relation.name:lower() == bare:lower() and (relation.schema or ''):lower() == schema:lower()
    then
      return relation
    end
  end
  return nil
end

local function relation_item(relation)
  local schema = relation.schema
  local qualified = (schema and schema ~= '') and (schema .. '.' .. relation.name) or relation.name
  return {
    word = relation.name,
    kind = relation.kind,
    menu = (schema and schema ~= '') and (relation.kind .. ' ' .. schema) or relation.kind,
    detail = qualified,
  }
end

local function column_item(relation, column, menu)
  local parts = { relation.name .. '.' .. column.name }
  if column.type ~= '' then
    parts[#parts + 1] = column.type
  end
  if column.pk > 0 then
    parts[#parts + 1] = 'PK'
  end
  if column.notnull then
    parts[#parts + 1] = 'NOT NULL'
  end
  if column.fk then
    parts[#parts + 1] = '-> ' .. column.fk
  end
  return { word = column.name, kind = 'column', menu = menu, detail = table.concat(parts, ' ') }
end

--- 'keep' follows the case being typed: an all-lower-case prefix keeps keywords lower-case.
local function cased(keyword, keyword_case, prefix)
  if keyword_case == 'lower' then
    return keyword:lower()
  end
  if keyword_case == 'keep' and prefix ~= '' and prefix == prefix:lower() then
    return keyword:lower()
  end
  return keyword
end

local function collect_keywords(items, keyword_case, prefix)
  for _, keyword in ipairs(KEYWORDS) do
    items[#items + 1] =
      { word = cased(keyword, keyword_case, prefix), kind = 'keyword', menu = 'keyword' }
  end
end

local function collect_relations(catalog, items)
  for _, relation in ipairs(catalog:all_relations()) do
    items[#items + 1] = relation_item(relation)
  end
end

--- Columns of every relation whose columns are loaded; the menu names the table they came from.
local function collect_all_columns(catalog, items)
  for _, relation in ipairs(catalog:all_relations()) do
    for _, column in ipairs(catalog:info_for(relation).columns or {}) do
      items[#items + 1] = column_item(relation, column, relation.name)
    end
  end
end

local function collect_qualified_columns(catalog, qualifier, aliases, items)
  if type(qualifier) ~= 'string' or qualifier == '' then
    return
  end
  local relation = find_relation(catalog, alias_target(aliases, qualifier) or qualifier)
  if not relation then
    return
  end
  for _, column in ipairs(catalog:info_for(relation).columns or {}) do
    items[#items + 1] = column_item(relation, column, column.type ~= '' and column.type or 'column')
  end
end

--- 0 for a prefix match, 1 for a substring match, nil when `word` does not match at all.
local function match_rank(word, needle)
  if needle == '' then
    return 0
  end
  local haystack, want = word:lower(), needle:lower()
  if haystack:sub(1, #want) == want then
    return 0
  end
  return haystack:find(want, 1, true) and 1 or nil
end

--- Keep the matches, prefix matches first, then alphabetically. The comparator is a total order,
--- so the result never depends on `table.sort` being stable.
local function rank_items(items, prefix)
  local scored = {}
  for _, item in ipairs(items) do
    local rank = match_rank(item.word, prefix)
    if rank then
      scored[#scored + 1] = { rank = rank, item = item }
    end
  end
  table.sort(scored, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    local aw, bw = a.item.word:lower(), b.item.word:lower()
    if aw ~= bw then
      return aw < bw
    end
    if a.item.word ~= b.item.word then
      return a.item.word < b.item.word
    end
    if a.item.kind ~= b.item.kind then
      return a.item.kind < b.item.kind
    end
    return a.item.menu < b.item.menu
  end)
  local out = {}
  for index, entry in ipairs(scored) do
    out[index] = entry.item
  end
  return out
end

--- Everything worth offering for `ctx`, already filtered and ordered.
---@param catalog dblens.Catalog
---@param ctx dblens.CompletionContext
---@param opts { keyword_case: string?, aliases: table<string, string>? }?
---@return dblens.CompletionItem[]
function M.candidates(catalog, ctx, opts)
  assert(
    type(catalog) == 'table' and catalog.all_relations,
    'completion.candidates: expected a catalog'
  )
  assert(
    type(ctx) == 'table' and type(ctx.prefix) == 'string',
    'completion.candidates: expected a context'
  )
  opts = opts or {}
  local items = {}
  if ctx.kind == 'column' then
    collect_qualified_columns(catalog, ctx.qualifier, opts.aliases, items)
  elseif ctx.kind == 'table' then
    collect_relations(catalog, items)
  else
    assert(ctx.kind == 'any', 'completion.candidates: unknown kind ' .. tostring(ctx.kind))
    collect_keywords(items, opts.keyword_case, ctx.prefix)
    collect_relations(catalog, items)
    collect_all_columns(catalog, items)
  end
  return rank_items(items, ctx.prefix)
end

--- Buffer text on each side of the cursor, clamped to a window of lines so that a long scratch
--- buffer cannot make every keystroke cost a full scan.
---@return string before, string after
local function cursor_window(bufnr, row, col)
  local total = vim.api.nvim_buf_line_count(bufnr)
  assert(row <= total, ('completion: row %d is past the end of buffer %d'):format(row, bufnr))
  local first = math.max(1, row - MAX_CONTEXT_LINES)
  local last = math.min(total, row + MAX_CONTEXT_LINES)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local at = row - first + 1
  local current = lines[at]
  assert(type(current) == 'string', 'completion: the cursor line is missing from the window')
  local before = vim.list_slice(lines, 1, at - 1)
  before[#before + 1] = current:sub(1, col)
  local after = vim.list_slice(lines, at + 1, #lines)
  table.insert(after, 1, current:sub(col + 1))
  return table.concat(before, '\n'), table.concat(after, '\n')
end

--- Split the window into the statement under the cursor: `head` ends at the cursor and drives the
--- context, `whole` runs to the end of the statement so an alias declared later still resolves.
---@return string head, string whole
local function statement_at(before, after, dialect)
  local start = 1
  for _, token in ipairs(sql.scan(before, dialect)) do
    if token.type == 'punct' and token.text == ';' then
      start = token.to + 1
    end
  end
  local head = before:sub(start)
  local whole = head .. after
  local stop = #whole
  for _, token in ipairs(sql.scan(whole, dialect)) do
    if token.type == 'punct' and token.text == ';' and token.from > #head then
      stop = token.from - 1
      break
    end
  end
  assert(stop >= #head, 'completion: the statement cannot end before the cursor')
  return head, whole:sub(1, stop)
end

--- Buffer -> its session resolver. Entries are dropped on BufWipeout and whenever a buffer turns
--- out to be gone, so this cannot grow without bound.
local resolvers = {}

--- The live session behind a buffer, or nil when it is unattached, gone, or not connected.
---@return dblens.Session?
local function session_for(bufnr)
  local resolve = resolvers[bufnr]
  if not resolve then
    return nil
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    resolvers[bufnr] = nil
    return nil
  end
  local session = resolve()
  if session == nil then
    return nil
  end
  assert(
    type(session) == 'table' and session.catalog and session.adapter,
    'completion: the resolver must return a session or nil'
  )
  return session
end

--- Completions for a cursor position in an attached buffer.
---
--- `min_chars` gates only the unfocused `any` list: a qualified `t.` or a FROM clause is specific
--- enough to be worth answering with no prefix at all.
---@param bufnr integer
---@param row integer  1-based line
---@param col integer  0-based byte column
---@return dblens.CompletionItem[] items, dblens.CompletionContext? ctx
function M.complete_at(bufnr, row, col)
  assert(type(row) == 'number' and row >= 1, 'completion.complete_at: row is 1-based')
  assert(type(col) == 'number' and col >= 0, 'completion.complete_at: col is a 0-based byte index')
  local session = session_for(bufnr)
  if not session then
    return {}, nil
  end
  local options = config.get().completion
  if not options.enabled then
    return {}, nil
  end
  local dialect = session.adapter.dialect
  local before, after = cursor_window(bufnr, row, col)
  local head, whole = statement_at(before, after, dialect)
  local ctx = M.context(head, dialect)
  if ctx.kind == 'any' and #ctx.prefix < (options.min_chars or 0) then
    return {}, ctx
  end
  local opts = { keyword_case = options.keyword_case, aliases = M.aliases(whole, dialect) }
  return M.candidates(session.catalog, ctx, opts), ctx
end

--- 0-based column where the word under the cursor starts. For a quoted identifier the opening
--- quote stays put, so inserting the plain name lands inside the quotes.
local function word_start(bufnr, row, col, dialect)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local head = line:sub(1, col)
  local toks = sql.tokens(head, dialect)
  local last = toks[#toks]
  if last and last.to == #head and (last.type == 'word' or last.type == 'ident') then
    return last.type == 'ident' and last.from or last.from - 1
  end
  return col
end

local VIM_KIND = { keyword = 'k', table = 't', view = 'v', column = 'c' }

--- Vim's omnifunc protocol. `findstart == 1` answers where the word starts, `0` answers with the
--- matches; `-3` cancels silently when the buffer has no live connection to ask.
---@param findstart integer
---@param _base string  unused: the prefix is re-read from the buffer
---@return integer|table[]
function M.omnifunc(findstart, _base)
  assert(findstart == 0 or findstart == 1, 'completion.omnifunc: findstart must be 0 or 1')
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  if findstart == 1 then
    local session = session_for(bufnr)
    if not session then
      return -3
    end
    return word_start(bufnr, row, col, session.adapter.dialect)
  end
  local out = {}
  for _, item in ipairs((M.complete_at(bufnr, row, col))) do
    out[#out + 1] = {
      word = item.word,
      menu = item.menu,
      kind = VIM_KIND[item.kind] or '',
      info = item.detail or '',
    }
  end
  return out
end

--- Require a plugin that may not be installed. A missing module is an expected outcome — the
--- omnifunc path still works — but any other load error is real and is reported.
---@param name string
---@return table?
function M.optional_require(name)
  assert(
    type(name) == 'string' and name ~= '',
    'completion.optional_require: expected a module name'
  )
  local ok, module = pcall(require, name)
  if ok then
    assert(type(module) == 'table', ('completion: `%s` did not return a module table'):format(name))
    return module
  end
  if not tostring(module):find('not found', 1, true) then
    vim.notify(('dblens: loading `%s` failed: %s'):format(name, module), vim.log.levels.WARN)
  end
  return nil
end

---@return boolean
function M.is_attached(bufnr)
  assert(type(bufnr) == 'number', 'completion.is_attached: bufnr must be a number')
  return resolvers[bufnr] ~= nil
end

--- Forget a buffer's resolver.
function M.detach(bufnr)
  assert(type(bufnr) == 'number', 'completion.detach: bufnr must be a number')
  resolvers[bufnr] = nil
end

--- Wire completion into one SQL buffer.
---
--- `resolve` is asked for the buffer's session on every request, so a reconnect or a disconnect is
--- picked up without re-attaching.
---@param bufnr integer  0 for the current buffer
---@param resolve fun(): dblens.Session?
---@return boolean attached  false when completion is disabled in the config
function M.attach(bufnr, resolve)
  assert(type(bufnr) == 'number', 'completion.attach: bufnr must be a number')
  assert(type(resolve) == 'function', 'completion.attach: resolve must be a function')
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  assert(
    vim.api.nvim_buf_is_valid(bufnr),
    ('completion.attach: buffer %d is not valid'):format(bufnr)
  )
  if not config.get().completion.enabled then
    return false
  end

  resolvers[bufnr] = resolve
  vim.api.nvim_set_option_value('omnifunc', OMNIFUNC, { buf = bufnr })
  -- Buffer-local, so Neovim drops the autocommand with the buffer; `once` keeps a re-attach clean.
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = vim.api.nvim_create_augroup('dblens.completion', { clear = false }),
    buffer = bufnr,
    once = true,
    callback = function()
      M.detach(bufnr)
    end,
  })
  require('dblens.completion.cmp').setup(bufnr)
  require('dblens.completion.blink').setup(bufnr)
  return true
end

return M
