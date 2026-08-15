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
--- What keeps the predicate safe is structural: no `;`, no comment, no backslash, no unsafe
--- punctuation, no unclosed quote. A write verb is refused only where it could OPEN a nested
--- statement — `REPLACE(...)`, a column called `comment` and `größe` are ordinary predicates, and
--- refusing them made a read-only browser unusable. A bare `x = 1 OR DELETE` now reaches the
--- server, which answers with a syntax error; it never had a way to modify anything.
---@param where string?
---@param dialect dblens.Dialect?
---@return string? error message, nil when the predicate is safe to splice
function M.check_predicate(where, dialect)
  if not where or vim.trim(where) == '' then
    return nil
  end
  if where:find('\\', 1, true) then
    return 'filter must not contain a backslash'
  end
  local code = {}
  for _, token in ipairs(sql.scan(where, dialect)) do
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

local function order_clause(order_by, dialect)
  if not order_by then
    return ''
  end
  assert(type(order_by.column) == 'string', 'common: order_by needs a column')
  return (' ORDER BY %s %s'):format(
    sql.quote_ident(order_by.column, dialect),
    order_by.desc and 'DESC' or 'ASC'
  )
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
    order_clause(opts.order_by, dialect),
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
