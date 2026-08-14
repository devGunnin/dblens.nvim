--- The schema explorer: renders the tree and turns keys into app actions.
local icons_mod = require('dblens.ui.icons')
local keymaps = require('dblens.keymaps')
local layout_mod = require('dblens.ui.layout')
local status = require('dblens.ui.status')
local tree = require('dblens.tree')

local api = vim.api

local M = {}

local NAMESPACE = api.nvim_create_namespace('dblens.sidebar')

local KIND_HL = {
  connection = 'DbLensTitle',
  schema = 'DbLensSchema',
  relation = 'DbLensTable',
  column = 'DbLensColumn',
  folder = 'DbLensDim',
  index = 'DbLensIndex',
  constraint = 'DbLensIndex',
  empty = 'DbLensDim',
}

local BADGE_HL = { PK = 'DbLensPK', FK = 'DbLensFK', NN = 'DbLensNN', UQ = 'DbLensIndex' }

--- Icon key for a node, distinguishing tables from views.
local function icon_key(node)
  if node.kind == 'relation' then
    return node.relation.kind == 'view' and 'view' or 'table'
  end
  return icons_mod.NODE[node.kind]
end

--- Build one tree line plus its highlight marks.
---@return string line, { col: integer, end_col: integer, hl: string }[]
local function compose(node, icons, line_index)
  local marks = {}
  local parts = { string.rep('  ', node.depth) }
  local bytes = #parts[1]

  local function add(text, hl)
    if text == '' then
      return
    end
    if hl then
      marks[#marks + 1] = { line = line_index, col = bytes, end_col = bytes + #text, hl = hl }
    end
    parts[#parts + 1] = text
    bytes = bytes + #text
  end

  local chevron = ' '
  if node.loading then
    chevron = icons.running
  elseif node.expandable then
    chevron = node.expanded and icons.expanded or icons.collapsed
  end
  add(chevron .. ' ', 'DbLensChevron')

  local glyph = icon_key(node)
  if glyph then
    add(icons[glyph] .. ' ', 'DbLensIcon')
  end
  add(node.label, KIND_HL[node.kind] or 'DbLensNormal')

  for _, badge in ipairs(node.badges or {}) do
    add(' ', nil)
    add(badge, BADGE_HL[badge] or 'DbLensDim')
  end
  if node.detail then
    add('  ' .. node.detail, 'DbLensDataType')
  end
  return table.concat(parts), marks
end

--- Redraw the tree.
---@param state dblens.State
function M.render(state)
  local buf, win = state.layout.bufs.sidebar, state.layout.wins.sidebar
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local icons = icons_mod.get(state.options.ui.icons)

  local nodes = {}
  if state.session then
    nodes = tree.flatten({
      name = state.session.spec.name,
      detail = state.session.adapter.label,
      catalog = state.session.catalog,
      expanded = state.tree.expanded,
      loading = state.tree.loading,
    })
  end
  state.tree.nodes = nodes

  local lines, marks = {}, {}
  if #nodes == 0 then
    lines = { '', '  no connection', '', '  press <leader>dc to pick one' }
    marks = { { line = 1, col = 0, end_col = #lines[2], hl = 'DbLensDim' } }
  end
  for index, node in ipairs(nodes) do
    local line, line_marks = compose(node, icons, index - 1)
    lines[index] = line
    vim.list_extend(marks, line_marks)
  end

  layout_mod.set_lines(buf, lines)
  api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
  for _, mark in ipairs(marks) do
    api.nvim_buf_set_extmark(
      buf,
      NAMESPACE,
      mark.line,
      mark.col,
      { end_col = mark.end_col, hl_group = mark.hl }
    )
  end

  if api.nvim_win_is_valid(win) then
    local session = state.session
    status.set(win, {
      {
        text = ' ' .. icons.database .. ' ' .. (session and session.spec.name or 'dblens'),
        hl = 'DbLensTitle',
      },
      { text = session and session:describe() or '', hl = 'DbLensDim' },
      {
        text = session and session:is_read_only() and (icons.lock .. ' read-only') or '',
        hl = 'DbLensReadOnly',
      },
    }, state.options)
  end
end

--- Node under the cursor, or nil.
---@return dblens.Node?
local function current_node(state)
  local win = state.layout.wins.sidebar
  if not api.nvim_win_is_valid(win) then
    return nil
  end
  return state.tree.nodes[api.nvim_win_get_cursor(win)[1]]
end

--- Expanding a branch loads it if it has never been loaded.
local function expand(state, app, node)
  state.tree.expanded[node.id] = true
  if node.kind == 'schema' then
    app.load_relations(node.schema)
  elseif node.kind == 'connection' and not state.session.catalog.has_schemas then
    app.load_relations('')
  elseif node.kind == 'relation' or node.kind == 'folder' then
    app.load_relation_details(node.relation)
  else
    app.render()
  end
end

local function toggle(state, app, node)
  if not node or not node.expandable then
    return
  end
  if state.tree.expanded[node.id] then
    state.tree.expanded[node.id] = nil
    app.render()
    return
  end
  expand(state, app, node)
end

--- Build the handler table. Kept together so every declared action is visibly implemented.
local function handlers(state, app)
  local function with_relation(fn)
    return function()
      local node = current_node(state)
      if not node or not node.relation then
        app.notify('put the cursor on a table')
        return
      end
      fn(node)
    end
  end

  return {
    select = function()
      local node = current_node(state)
      if not node then
        return
      end
      if node.kind == 'relation' then
        app.open_relation(node.relation)
        return
      end
      toggle(state, app, node)
    end,
    toggle_node = function()
      toggle(state, app, current_node(state))
    end,
    collapse_all = function()
      state.tree.expanded = { [tree.connection_id()] = true }
      app.render()
    end,
    find = function()
      require('dblens.ui.picker').tables(state)
    end,
    open = with_relation(function(node)
      app.open_relation(node.relation)
    end),
    row_count = with_relation(function(node)
      app.count_rows(node.relation)
    end),
    ddl = with_relation(function(node)
      require('dblens.ui.detail').ddl(state, node.relation)
    end),
    refresh = function()
      if not state.session then
        return
      end
      state.session.catalog:clear()
      app.expand_default_schema()
      app.notify('schema reloaded')
    end,
    help = function()
      require('dblens.ui.help').show(state, 'sidebar')
    end,
    close = function()
      app.close()
    end,
  }
end

--- Bind the sidebar's keys once, when the layout is built.
---@param state dblens.State
function M.attach(state)
  local app = require('dblens.app')
  keymaps.bind(
    'sidebar',
    state.layout.bufs.sidebar,
    handlers(state, app),
    state.options.keymaps.sidebar
  )
end

return M
