--- Statement fragments and the argv-safety rule shared by every adapter.
---
--- Paging, sorting and filtering are ANSI enough that all three clients take the same shape;
--- only quoting differs, and that comes in via the dialect.
local sql = require('dblens.sql')

local M = {}

--- Whether a connection field would reach the client as an OPTION rather than as data.
---
--- Every field that becomes an argv element has to pass this. A client's option parser reads a
--- leading `-` wherever it appears, so an unchecked `--host=elsewhere` or `--local-infile=1` in a
--- spec is a flag the adapter's own flags cannot override — and since discovery builds specs out
--- of untrusted repo text, that is the whole exposure. Nothing legitimate (host, user, database,
--- file path) starts with `-`; `dblens.path` states the same rule for the file-backed engines.
---@param value any        -- nil and non-strings are somebody else's check
---@param label string     -- ``<engine> `<field>` ``, for the message
---@return string? error
function M.option_like_problem(value, label)
  assert(type(label) == 'string' and label ~= '', 'common.option_like_problem: needs a label')
  if type(value) == 'string' and value:sub(1, 1) == '-' then
    return ('%s must not start with `-`: the client would read it as an option'):format(label)
  end
  return nil
end

--- The same rule over several fields of one spec, in a fixed order so the message is stable.
---@param spec table
---@param engine string
---@param fields string[]
---@return string? error
function M.argv_field_problem(spec, engine, fields)
  assert(type(spec) == 'table', 'common.argv_field_problem: expected a spec')
  assert(#fields > 0, 'common.argv_field_problem: needs at least one field')
  for _, field in ipairs(fields) do
    local problem = M.option_like_problem(spec[field], ('%s `%s`'):format(engine, field))
    if problem then
      return problem
    end
  end
  return nil
end

---@class dblens.Relation
---@field schema string?
---@field name string
---@field kind 'table'|'view'

--- Fully-qualified, correctly quoted relation reference.
---@param relation dblens.Relation
---@param dialect dblens.Dialect
---@return string
function M.qualify(relation, dialect)
  assert(type(relation) == 'table' and relation.name, 'common.qualify: relation needs a name')
  local name = sql.quote_ident(relation.name, dialect)
  if relation.schema and relation.schema ~= '' then
    return sql.quote_ident(relation.schema, dialect) .. '.' .. name
  end
  return name
end

---@class dblens.PageOpts
---@field limit integer
---@field offset integer
---@field order_by { column: string, desc: boolean }?
---@field tiebreak string[]?  -- columns appended ascending, so a sort on a non-unique column is total
---@field where string?  -- raw SQL predicate typed by the user

--- Check a user-typed filter predicate before it is spliced into generated SQL.
---
--- The filter bar takes raw SQL by design, but a predicate must stay one read-only expression
--- that cannot detach the `LIMIT`/`OFFSET` appended after it. This is an ALLOW-list, because the
--- deny-list version of it let through `\!` (psql runs it as a shell command mid-statement),
--- `--` and `/*` (which comment the pagination out), and a backslash inside a literal (whose
--- meaning depends on a server setting, so the lexer and the server can disagree about where
--- the string ends and a stacked statement becomes invisible).
---
--- What keeps the predicate safe is structural: no `;`, no comment, no unsafe punctuation (which
--- is where a bare `\` lands — psql runs `\!` as a shell command), no unclosed quote, and no
--- backslash INSIDE a literal on a dialect where one may escape. A write verb is refused only
--- where it could OPEN a nested statement — `REPLACE(...)`, a column called `comment` and `größe`
--- are ordinary predicates, and refusing them made a read-only browser unusable. A bare
--- `x = 1 OR DELETE` now reaches the server, which answers with a syntax error; it never had a
--- way to modify anything.
---
--- The backslash rule is the dialect's own `backslash_escape`, the same flag `sql.scan` frames
--- literals with, so the lexer and this check cannot disagree. What makes that flag TRUE is not
--- assumed anywhere: mysql and mariadb read a backslash one way under `NO_BACKSLASH_ESCAPES` and
--- another without it, so the adapter clears that mode on connect; postgres reads one way under
--- `standard_conforming_strings` and another without it, so `quote_literal` emits `E'...'`
--- (unambiguous in both) and the adapter pins the setting as well. sqlite, duckdb and mssql have
--- no such escape in a plain literal. So a Windows path or a regex is an ordinary value on the
--- four that do not branch, and refusing it was a usability hole with nothing behind it. An
--- unknown dialect scans as `permissive`, which does escape, so an unrecognised engine is refused.
---@param where string?
---@param dialect dblens.Dialect?
---@return string? error message, nil when the predicate is safe to splice
function M.check_predicate(where, dialect)
  if not where or vim.trim(where) == '' then
    return nil
  end
  local d = dialect or sql.dialects.permissive
  local code = {}
  for _, token in ipairs(sql.scan(where, d)) do
    if token.type == 'comment' then
      return 'filter must not contain a comment'
    end
    if token.type == 'exec_comment' then
      return 'filter must not contain an executable `/*!` comment'
    end
    if token.type == 'punct' and not sql.SAFE_PUNCT[token.text] then
      return ('filter must not contain `%s`'):format(token.text)
    end
    if (token.type == 'string' or token.type == 'ident') and token.closed == false then
      return 'filter has an unclosed quote'
    end
    if token.type == 'string' and d.backslash_escape and token.text:find('\\', 1, true) then
      return 'filter must not contain a backslash on this engine, where it may be an escape'
    end
    if token.type ~= 'space' then
      code[#code + 1] = token
    end
  end
  for index, token in ipairs(code) do
    if
      token.type == 'word'
      and sql.is_write_verb(token.text, dialect)
      and sql.opens_statement(code, index, dialect)
    then
      return ('filter must not contain `%s`'):format(token.text:upper())
    end
  end
  return nil
end

local function where_clause(where, dialect)
  if not where or vim.trim(where) == '' then
    return ''
  end
  assert(
    M.check_predicate(where, dialect) == nil,
    'common: unsafe predicate reached SQL generation'
  )
  return ' WHERE ' .. vim.trim(where)
end

--- `ORDER BY sort [, tiebreak...]`.
---
--- The tiebreak exists so a sort on a non-unique column has ONE answer: two rows that compare
--- equal are otherwise returned in whatever order the plan produced, so the same export run twice
--- can differ. It is only ever appended to a sort the caller asked for — an unsorted read is left
--- unsorted rather than paying for a whole-table sort nothing asked for.
---@param order_by { column: string, desc: boolean }?
---@param tiebreak string[]?
---@param dialect dblens.Dialect
---@return string
local function order_clause(order_by, tiebreak, dialect)
  if not order_by then
    assert(not tiebreak or #tiebreak == 0, 'common: a tiebreak needs a sort to break ties in')
    return ''
  end
  assert(type(order_by.column) == 'string', 'common: order_by needs a column')
  local keys = {
    ('%s %s'):format(sql.quote_ident(order_by.column, dialect), order_by.desc and 'DESC' or 'ASC'),
  }
  for _, column in ipairs(tiebreak or {}) do
    assert(type(column) == 'string' and column ~= '', 'common: a tiebreak column needs a name')
    if column ~= order_by.column then
      keys[#keys + 1] = sql.quote_ident(column, dialect) .. ' ASC'
    end
  end
  return ' ORDER BY ' .. table.concat(keys, ', ')
end

--- `SELECT * FROM rel [WHERE ...] [ORDER BY ...] LIMIT n OFFSET k`.
---@param relation dblens.Relation
---@param opts dblens.PageOpts
---@param dialect dblens.Dialect
---@return string
function M.page(relation, opts, dialect)
  assert(type(opts.limit) == 'number' and opts.limit > 0, 'common.page: limit must be positive')
  assert(
    type(opts.offset) == 'number' and opts.offset >= 0,
    'common.page: offset must not be negative'
  )
  return ('SELECT * FROM %s%s%s LIMIT %d OFFSET %d'):format(
    M.qualify(relation, dialect),
    where_clause(opts.where, dialect),
    order_clause(opts.order_by, opts.tiebreak, dialect),
    opts.limit,
    opts.offset
  )
end

--- `SELECT count(*) FROM rel [WHERE ...]`.
function M.count(relation, where, dialect)
  return ('SELECT count(*) AS n FROM %s%s'):format(
    M.qualify(relation, dialect),
    where_clause(where, dialect)
  )
end

--- `col = value`, `col <> value`, or the NULL-safe form of either.
---
--- `<>` rather than `!=`: both are accepted by all six engines, `<>` is the standard spelling.
---@param column string
---@param value any        -- a cell value, or protocol.NULL / nil for SQL NULL
---@param op '='|'<>'
---@param dialect dblens.Dialect
---@return string
function M.compare_where(column, value, op, dialect)
  assert(op == '=' or op == '<>', 'common.compare_where: op must be `=` or `<>`')
  local ident = sql.quote_ident(column, dialect)
  if value == nil or value == vim.NIL then
    return ident .. (op == '=' and ' IS NULL' or ' IS NOT NULL')
  end
  return ('%s %s %s'):format(ident, op, sql.quote_literal(tostring(value), dialect))
end

--- A filter predicate built from a cell the user put the cursor on.
---
--- The value is QUOTED, never concatenated, and the result then goes through the same
--- `check_predicate` vetting as a hand-typed filter — which is what makes the refusal a message
--- rather than the assertion in `where_clause`. A value the vetting cannot express (a backslash,
--- whose meaning depends on a server setting) is reported here instead of reaching the server.
---@param column string
---@param value any
---@param op '='|'<>'
---@param dialect dblens.Dialect
---@return string? predicate, string? error
function M.cell_predicate(column, value, op, dialect)
  assert(type(column) == 'string' and column ~= '', 'common.cell_predicate: needs a column')
  if type(value) == 'string' and value:find('%z') then
    return nil, ('cannot filter on `%s`: the value contains a NUL byte'):format(column)
  end
  local predicate = M.compare_where(column, value, op, dialect)
  local problem = M.check_predicate(predicate, dialect)
  if problem then
    return nil, ('cannot filter on this value (%s)'):format(problem)
  end
  return predicate, nil
end

--- Predicate matching exactly the given column values, for row-targeted CRUD.
---@param values { column: string, value: any }[]
---@param dialect dblens.Dialect
---@return string
function M.match_where(values, dialect)
  assert(#values > 0, 'common.match_where: refusing to build an empty predicate')
  local parts = {}
  for _, entry in ipairs(values) do
    local column = sql.quote_ident(entry.column, dialect)
    if entry.value == nil or entry.value == vim.NIL then
      parts[#parts + 1] = column .. ' IS NULL'
    else
      parts[#parts + 1] = column .. ' = ' .. sql.quote_literal(tostring(entry.value), dialect)
    end
  end
  return table.concat(parts, ' AND ')
end

return M
