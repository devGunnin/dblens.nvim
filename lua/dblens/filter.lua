--- The filter builder's operators, and the predicates they compose.
---
--- Pure: no vim UI and no state, so every case here is a unit test. A predicate is assembled from
--- QUOTED parts — `sql.quote_ident` for the column, `sql.quote_literal` for every value — and then
--- vetted by `common.check_predicate`, the same allow-list a hand-typed WHERE passes. Nothing
--- reaching this module is ever concatenated into SQL: a value holding `'`, `;` or `--` is a
--- literal, and a column named `select` is a name.
local common = require('dblens.adapters.common')
local sql = require('dblens.sql')

local M = {}

---@class dblens.FilterOperator
---@field id string       -- the SQL dblens emits; also the stable id the UI hands back
---@field label string    -- what the menu shows
---@field detail string   -- dimmed menu hint
---@field arity 'none'|'one'|'two'|'list'
---@field wildcard boolean?  -- the value prompt starts wrapped in `%...%`
---@field ilike boolean?     -- offered only where the engine has ILIKE

--- `<>` rather than `!=` as the emitted spelling, for the reason `common.compare_where` gives:
--- both work everywhere, `<>` is the standard one. The menu still LABELS it `!=`.
---@type dblens.FilterOperator[]
M.OPERATORS = {
  { id = '=', label = '=', detail = 'equals', arity = 'one' },
  { id = '<>', label = '!=', detail = 'not equal', arity = 'one' },
  { id = '>', label = '>', detail = 'greater than', arity = 'one' },
  { id = '>=', label = '>=', detail = 'at least', arity = 'one' },
  { id = '<', label = '<', detail = 'less than', arity = 'one' },
  { id = '<=', label = '<=', detail = 'at most', arity = 'one' },
  { id = 'BETWEEN', label = 'BETWEEN', detail = 'inclusive range, two values', arity = 'two' },
  { id = 'IN', label = 'IN', detail = 'one of a comma-separated list', arity = 'list' },
  { id = 'LIKE', label = 'LIKE', detail = 'pattern: % and _', arity = 'one', wildcard = true },
  {
    id = 'NOT LIKE',
    label = 'NOT LIKE',
    detail = 'pattern that must not match',
    arity = 'one',
    wildcard = true,
  },
  {
    id = 'ILIKE',
    label = 'ILIKE',
    detail = 'pattern, case-insensitive',
    arity = 'one',
    wildcard = true,
    ilike = true,
  },
  {
    id = 'NOT ILIKE',
    label = 'NOT ILIKE',
    detail = 'case-insensitive pattern that must not match',
    arity = 'one',
    wildcard = true,
    ilike = true,
  },
  { id = 'IS NULL', label = 'IS NULL', detail = 'no value needed', arity = 'none' },
  { id = 'IS NOT NULL', label = 'IS NOT NULL', detail = 'has a value', arity = 'none' },
}

local BY_ID = {}
for _, operator in ipairs(M.OPERATORS) do
  BY_ID[operator.id] = operator
end

--- Menu order per column class: what is worth reaching first on that kind of column. Each list
--- names every operator exactly once, so the menu is a re-ordering and never a subset — the
--- integrity check below holds that true rather than trusting the lists to be edited together.
local ORDER = {
  numeric = {
    '=',
    '<>',
    '>',
    '>=',
    '<',
    '<=',
    'BETWEEN',
    'IN',
    'IS NULL',
    'IS NOT NULL',
    'LIKE',
    'NOT LIKE',
    'ILIKE',
    'NOT ILIKE',
  },
  text = {
    '=',
    '<>',
    'LIKE',
    'NOT LIKE',
    'ILIKE',
    'NOT ILIKE',
    'IN',
    'IS NULL',
    'IS NOT NULL',
    '>',
    '>=',
    '<',
    '<=',
    'BETWEEN',
  },
  other = {
    '=',
    '<>',
    'IN',
    'IS NULL',
    'IS NOT NULL',
    'LIKE',
    'NOT LIKE',
    'ILIKE',
    'NOT ILIKE',
    '>',
    '>=',
    '<',
    '<=',
    'BETWEEN',
  },
}
-- A date is compared and ranged like a number.
ORDER.temporal = ORDER.numeric

for class, order in pairs(ORDER) do
  local seen = {}
  for _, id in ipairs(order) do
    assert(BY_ID[id], ('filter: the %s order names unknown operator `%s`'):format(class, id))
    assert(not seen[id], ('filter: the %s order names `%s` twice'):format(class, id))
    seen[id] = true
  end
  assert(#order == #M.OPERATORS, ('filter: the %s order is missing an operator'):format(class))
end

--- Type fragments that decide a column's class. Temporal is tested FIRST because `interval` and
--- postgres's `point` both contain `int`.
local TYPE_CLASS = {
  { class = 'temporal', fragments = { 'date', 'time', 'year', 'interval' } },
  {
    class = 'numeric',
    fragments = { 'int', 'serial', 'numeric', 'decimal', 'real', 'double', 'float', 'money' },
  },
  {
    class = 'text',
    fragments = { 'char', 'text', 'string', 'clob', 'uuid', 'enum', 'json' },
  },
}

--- Best-effort class of a column, from the type the catalog recorded. An unloaded or unrecognised
--- type is `other`, which still offers every operator — just in a neutral order.
---@param column_type string?
---@return 'numeric'|'temporal'|'text'|'other'
function M.classify(column_type)
  if type(column_type) ~= 'string' or column_type == '' then
    return 'other'
  end
  local lowered = column_type:lower()
  for _, entry in ipairs(TYPE_CLASS) do
    for _, fragment in ipairs(entry.fragments) do
      if lowered:find(fragment, 1, true) then
        return entry.class
      end
    end
  end
  return 'other'
end

--- The operators to offer for one cell, most useful first.
---
--- A NULL cell puts the two that need no value at the front: there is nothing to compare it to,
--- and `IS NULL` is what the user came for.
---@param opts { type: string?, is_null: boolean?, ilike: boolean? }
---@return dblens.FilterOperator[]
function M.menu(opts)
  assert(type(opts) == 'table', 'filter.menu: expected an options table')
  local order = ORDER[M.classify(opts.type)]
  assert(order, 'filter.menu: no menu order for this column class')
  local head, tail = {}, {}
  for _, id in ipairs(order) do
    local operator = BY_ID[id]
    if not operator.ilike or opts.ilike == true then
      local first = opts.is_null == true and operator.arity == 'none'
      local into = first and head or tail
      into[#into + 1] = operator
    end
  end
  vim.list_extend(head, tail)
  assert(#head > 0, 'filter.menu: every operator was filtered out')
  return head
end

--- Split an `IN` list on commas, trimming each entry.
---
--- An empty entry is dropped, so a trailing comma is forgiving. A value that itself contains a
--- comma cannot be written here — `=` takes it whole.
---@param text string
---@return string[]? values, string? error
function M.split_list(text)
  assert(type(text) == 'string', 'filter.split_list: expected text')
  local values = {}
  for part in text:gmatch('[^,]+') do
    local trimmed = vim.trim(part)
    if trimmed ~= '' then
      values[#values + 1] = trimmed
    end
  end
  if #values == 0 then
    return nil, 'IN needs at least one value'
  end
  return values, nil
end

--- How many values each arity takes; `list` takes any number, so it is absent.
local ARITY_COUNT = { none = 0, one = 1, two = 2 }

--- The predicate text itself, every part already quoted for the dialect.
---@return string
local function compose(ident, operator, values, dialect)
  if operator.arity == 'none' then
    return ident .. ' ' .. operator.id
  end
  if operator.arity == 'two' then
    return ('%s BETWEEN %s AND %s'):format(
      ident,
      sql.quote_literal(values[1], dialect),
      sql.quote_literal(values[2], dialect)
    )
  end
  if operator.arity == 'list' then
    local literals = {}
    for index, value in ipairs(values) do
      literals[index] = sql.quote_literal(value, dialect)
    end
    return ('%s IN (%s)'):format(ident, table.concat(literals, ', '))
  end
  return ('%s %s %s'):format(ident, operator.id, sql.quote_literal(values[1], dialect))
end

--- Build one predicate: `<column> <operator> <value...>`, quoted and then vetted.
---
--- The refusals are the same two `common.cell_predicate` has, for the same reasons: a NUL byte no
--- client can carry in argv, and a value the predicate allow-list cannot express (a backslash on
--- an engine where it may escape). Both come back as a message naming the column, never as an
--- assertion from inside the quoter.
---@param column string
---@param op_id string       -- an id from `M.OPERATORS`
---@param values string[]    -- as many as the operator's arity takes
---@param dialect dblens.Dialect
---@return string? predicate, string? error
function M.build(column, op_id, values, dialect)
  assert(type(column) == 'string' and column ~= '', 'filter.build: needs a column')
  assert(vim.islist(values), 'filter.build: values must be a list')
  local operator = BY_ID[op_id]
  assert(operator, ('filter.build: unknown operator `%s`'):format(tostring(op_id)))
  local wanted = ARITY_COUNT[operator.arity]
  if wanted then
    assert(
      #values == wanted,
      ('filter.build: `%s` takes %d value(s), got %d'):format(operator.id, wanted, #values)
    )
  else
    assert(#values > 0, 'filter.build: `IN` needs at least one value')
  end

  if column:find('%z') then
    return nil, 'cannot filter on a column whose name contains a NUL byte'
  end
  for _, value in ipairs(values) do
    assert(type(value) == 'string', 'filter.build: a value must be a string')
    if value:find('%z') then
      return nil, ('cannot filter on `%s`: the value contains a NUL byte'):format(column)
    end
  end

  local predicate = compose(sql.quote_ident(column, dialect), operator, values, dialect)
  local problem = common.check_predicate(predicate, dialect)
  if problem then
    return nil, ('cannot filter on this value (%s)'):format(problem)
  end
  return predicate, nil
end

--- AND the new predicate onto the one already applied.
---
--- Both sides are parenthesised: the filter bar takes raw SQL, so an `OR` on either side would
--- otherwise change meaning as soon as something was ANDed to it.
---@param existing string?
---@param predicate string
---@return string
function M.combine(existing, predicate)
  assert(type(predicate) == 'string' and predicate ~= '', 'filter.combine: needs a predicate')
  local current = vim.trim(existing or '')
  if current == '' then
    return predicate
  end
  return ('(%s) AND (%s)'):format(current, predicate)
end

return M
