--- The interactive filter builder: an operator menu on the column under the cursor, values
--- prefilled from the cell, then how the result joins a filter already applied.
---
--- This module collects INPUT and nothing else. The predicate is built and vetted by
--- `dblens.filter` behind `app.filter_with`, so no SQL text is assembled here.
local filter = require('dblens.filter')
local picker = require('dblens.ui.picker')
local protocol = require('dblens.protocol')

local M = {}

--- What the value prompt starts with: the cell under the cursor, wrapped in `%...%` for a pattern
--- operator so the wildcards are visible and editable rather than assumed.
---@return string
local function prefill(cell, operator)
  local text = protocol.tostring(cell.value)
  if operator.wildcard and text ~= '' then
    return '%' .. text .. '%'
  end
  return text
end

--- The prompts one operator needs, in order. `IS NULL` / `IS NOT NULL` need none.
---
--- Public because it is the whole "prefilled from the cell" behaviour, and a pure description of
--- it is worth asserting on directly.
---@param cell dblens.Cell
---@param operator dblens.FilterOperator
---@return { label: string, default: string }[]
function M.prompts_for(cell, operator)
  assert(
    type(operator) == 'table' and operator.arity,
    'filterbuilder.prompts_for: needs an operator'
  )
  assert(
    type(cell) == 'table' and type(cell.name) == 'string',
    'filterbuilder.prompts_for: needs a cell'
  )
  if operator.arity == 'none' then
    return {}
  end
  if operator.arity == 'two' then
    return {
      { label = ('%s BETWEEN '):format(cell.name), default = prefill(cell, operator) },
      { label = 'AND ', default = '' },
    }
  end
  local label = operator.arity == 'list' and ('%s IN '):format(cell.name)
    or ('%s %s '):format(cell.name, operator.label)
  return { { label = label, default = prefill(cell, operator) } }
end

--- Ask for each value in turn, then hand the whole list on. Cancelling any prompt abandons the
--- filter, leaving the grid exactly as it was.
---@param prompts { label: string, default: string }[]
---@param index integer
---@param values string[]
---@param done fun(values: string[])
local function ask(prompts, index, values, done)
  assert(index <= #prompts + 1, 'filterbuilder.ask: asked past the last prompt')
  assert(#prompts <= 2, 'filterbuilder.ask: no operator takes more than two values')
  if index > #prompts then
    done(values)
    return
  end
  vim.ui.input({ prompt = prompts[index].label, default = prompts[index].default }, function(input)
    if input == nil then
      return
    end
    values[index] = input
    ask(prompts, index + 1, values, done)
  end)
end

--- Apply the filter, asking how it joins one already on screen.
local function apply(state, cell, operator, values)
  local app = require('dblens.app')
  if not state.grid.filter then
    app.filter_with(cell.name, operator.id, values, 'replace')
    return
  end
  picker.select(state, {
    title = 'A filter is already applied',
    choose_hint = 'use',
    items = {
      { text = 'AND with the current filter', detail = state.grid.filter, value = 'and' },
      { text = 'Replace the current filter', detail = 'drop it', value = 'replace' },
    },
    on_choose = function(mode)
      app.filter_with(cell.name, operator.id, values, mode)
    end,
  })
end

--- Collect the values for the picked operator and apply them.
local function collect(state, cell, operator)
  local app = require('dblens.app')
  ask(M.prompts_for(cell, operator), 1, {}, function(values)
    if operator.arity ~= 'list' then
      apply(state, cell, operator, values)
      return
    end
    local parsed, problem = filter.split_list(values[1])
    if not parsed then
      app.notify(problem)
      return
    end
    apply(state, cell, operator, parsed)
  end)
end

--- Open the operator menu for the cell under the cursor.
---@param state dblens.State
---@param cell dblens.Cell
function M.open(state, cell)
  local app = require('dblens.app')
  assert(type(cell) == 'table' and type(cell.name) == 'string', 'filterbuilder.open: needs a cell')
  local session = state.session
  if not session then
    app.error('not connected')
    return
  end
  local source = state.grid.source
  if not source or source.kind ~= 'relation' then
    app.notify('filtering needs a table; add a WHERE to the query instead')
    return
  end

  local column = session.catalog:column(source.relation, cell.name)
  local operators = filter.menu({
    type = column and column.type or nil,
    is_null = cell.value == nil or cell.value == protocol.NULL,
    ilike = session.adapter.caps.ilike == true,
  })
  local items = {}
  for _, operator in ipairs(operators) do
    items[#items + 1] = { text = operator.label, detail = operator.detail, value = operator }
  end
  picker.select(state, {
    title = ('Filter %s'):format(cell.name),
    items = items,
    choose_hint = 'use',
    on_choose = function(operator)
      collect(state, cell, operator)
    end,
  })
end

return M
