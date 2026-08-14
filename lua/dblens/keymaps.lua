--- The keymap registry: one declaration per binding, used by three consumers.
---
--- Binding, the `?` help overlay and the documentation all read this table, so a bind can never
--- drift from the help text describing it. Handlers are supplied by the UI module that owns the
--- scope; binding asserts every action has one, which turns a rename into a loud failure.
local M = {}

---@class dblens.KeySpec
---@field action string
---@field lhs string|string[]
---@field desc string
---@field mode string|string[]
---@field group string  -- section heading in the help overlay

---@type table<string, dblens.KeySpec[]>
M.specs = {
  --- Bound globally by `setup`, under one mnemonic prefix.
  global = {
    { action = 'toggle', lhs = '<leader>dd', desc = 'Toggle dblens', mode = 'n', group = 'dblens' },
    {
      action = 'connections',
      lhs = '<leader>dc',
      desc = 'Pick a connection',
      mode = 'n',
      group = 'dblens',
    },
    {
      action = 'query',
      lhs = '<leader>dq',
      desc = 'Focus the SQL editor',
      mode = 'n',
      group = 'dblens',
    },
    { action = 'tables', lhs = '<leader>dt', desc = 'Find a table', mode = 'n', group = 'dblens' },
    {
      action = 'history',
      lhs = '<leader>dh',
      desc = 'Query history',
      mode = 'n',
      group = 'dblens',
    },
    {
      action = 'snippets',
      lhs = '<leader>ds',
      desc = 'Saved snippets',
      mode = 'n',
      group = 'dblens',
    },
    {
      action = 'write_toggle',
      lhs = '<leader>dw',
      desc = 'Lock the connection / open it for editing',
      mode = 'n',
      group = 'dblens',
    },
    {
      action = 'txn_begin',
      lhs = '<leader>dB',
      desc = 'Begin transaction',
      mode = 'n',
      group = 'transaction',
    },
    {
      action = 'txn_commit',
      lhs = '<leader>dC',
      desc = 'Commit transaction',
      mode = 'n',
      group = 'transaction',
    },
    {
      action = 'txn_rollback',
      lhs = '<leader>dR',
      desc = 'Roll back transaction',
      mode = 'n',
      group = 'transaction',
    },
    {
      action = 'txn_pending',
      lhs = '<leader>dP',
      desc = 'Show pending changes',
      mode = 'n',
      group = 'transaction',
    },
  },

  sidebar = {
    {
      action = 'select',
      lhs = '<CR>',
      desc = 'Expand, or open the table',
      mode = 'n',
      group = 'navigate',
    },
    {
      action = 'toggle_node',
      lhs = '<Tab>',
      desc = 'Expand / collapse',
      mode = 'n',
      group = 'navigate',
    },
    {
      action = 'collapse_all',
      lhs = 'zM',
      desc = 'Collapse everything',
      mode = 'n',
      group = 'navigate',
    },
    { action = 'find', lhs = '/', desc = 'Find a table', mode = 'n', group = 'navigate' },
    {
      action = 'open',
      lhs = 'o',
      desc = 'Open the table in the grid',
      mode = 'n',
      group = 'table',
    },
    { action = 'row_count', lhs = 'c', desc = 'Count rows', mode = 'n', group = 'table' },
    { action = 'ddl', lhs = 'D', desc = 'Show the DDL', mode = 'n', group = 'table' },
    { action = 'refresh', lhs = 'R', desc = 'Reload the schema', mode = 'n', group = 'table' },
    { action = 'help', lhs = '?', desc = 'This help', mode = 'n', group = 'window' },
    { action = 'close', lhs = 'q', desc = 'Close dblens', mode = 'n', group = 'window' },
  },

  results = {
    {
      action = 'detail',
      lhs = { '<CR>', 'K' },
      desc = 'Row detail',
      mode = 'n',
      group = 'inspect',
    },
    { action = 'next_page', lhs = ']p', desc = 'Next page', mode = 'n', group = 'inspect' },
    { action = 'prev_page', lhs = '[p', desc = 'Previous page', mode = 'n', group = 'inspect' },
    { action = 'sort', lhs = 's', desc = 'Sort by this column', mode = 'n', group = 'inspect' },
    { action = 'filter', lhs = 'f', desc = 'Filter rows (WHERE)', mode = 'n', group = 'inspect' },
    { action = 'refresh', lhs = 'R', desc = 'Re-run the query', mode = 'n', group = 'inspect' },
    { action = 'edit_cell', lhs = 'e', desc = 'Edit this cell', mode = 'n', group = 'edit' },
    { action = 'insert_row', lhs = 'i', desc = 'Insert a row', mode = 'n', group = 'edit' },
    { action = 'delete_row', lhs = 'dd', desc = 'Delete this row', mode = 'n', group = 'edit' },
    { action = 'yank_cell', lhs = 'y', desc = 'Yank the cell', mode = 'n', group = 'yank' },
    { action = 'yank_row', lhs = 'Y', desc = 'Yank the row as CSV', mode = 'n', group = 'yank' },
    { action = 'yank_json', lhs = 'gy', desc = 'Yank the row as JSON', mode = 'n', group = 'yank' },
    {
      action = 'yank_insert',
      lhs = 'gi',
      desc = 'Yank the row as INSERT',
      mode = 'n',
      group = 'yank',
    },
    {
      action = 'export',
      lhs = 'X',
      desc = 'Export the result to a file',
      mode = 'n',
      group = 'yank',
    },
    { action = 'help', lhs = '?', desc = 'This help', mode = 'n', group = 'window' },
    { action = 'close', lhs = 'q', desc = 'Close dblens', mode = 'n', group = 'window' },
  },

  editor = {
    {
      action = 'run',
      lhs = '<CR>',
      desc = 'Run the statement at the cursor',
      mode = 'n',
      group = 'run',
    },
    {
      action = 'run_selection',
      lhs = '<CR>',
      desc = 'Run the selection',
      mode = 'x',
      group = 'run',
    },
    {
      action = 'run_all',
      lhs = '<localleader>r',
      desc = 'Run the whole buffer',
      mode = 'n',
      group = 'run',
    },
    {
      action = 'explain',
      lhs = '<localleader>e',
      desc = 'EXPLAIN the statement',
      mode = 'n',
      group = 'run',
    },
    {
      action = 'explain_analyze',
      lhs = '<localleader>E',
      desc = 'EXPLAIN ANALYZE',
      mode = 'n',
      group = 'run',
    },
    {
      action = 'cancel',
      lhs = '<C-c>',
      desc = 'Cancel the running query',
      mode = 'n',
      group = 'run',
    },
    {
      action = 'save_snippet',
      lhs = '<localleader>s',
      desc = 'Save as a snippet',
      mode = 'n',
      group = 'library',
    },
    {
      action = 'history',
      lhs = '<localleader>h',
      desc = 'Query history',
      mode = 'n',
      group = 'library',
    },
    { action = 'help', lhs = '?', desc = 'This help', mode = 'n', group = 'window' },
    {
      action = 'close',
      lhs = '<localleader>q',
      desc = 'Close dblens',
      mode = 'n',
      group = 'window',
    },
  },
}

--- Resolve a scope's bindings against the user's overrides.
---
--- An override of `false` disables the binding. An unknown action name is an error rather than a
--- silent no-op, because a typo there is otherwise invisible.
---@param scope string
---@param overrides table<string, string|string[]|false>|false|nil  -- false disables the scope
---@return { spec: dblens.KeySpec, lhs: string[] }[]
function M.resolve(scope, overrides)
  local specs = M.specs[scope]
  assert(specs, ('keymaps.resolve: unknown scope `%s`'):format(tostring(scope)))
  if overrides == false then
    -- Whole-scope opt-out. `<leader>d` in particular is contended, and turning the ten global
    -- maps off one action at a time is not a real escape hatch.
    return {}
  end
  overrides = overrides or {}

  local known = {}
  for _, spec in ipairs(specs) do
    known[spec.action] = true
  end
  for action in pairs(overrides) do
    if not known[action] then
      error(('dblens: unknown keymap action `keymaps.%s.%s`'):format(scope, action), 0)
    end
  end

  local out = {}
  for _, spec in ipairs(specs) do
    local override = overrides[spec.action]
    local lhs = override == nil and spec.lhs or override
    if lhs ~= false then
      out[#out + 1] = { spec = spec, lhs = type(lhs) == 'table' and lhs or { lhs } }
    end
  end
  return out
end

--- Bind a scope's keys in one buffer.
---@param scope string
---@param bufnr integer
---@param handlers table<string, function>
---@param overrides table?
function M.bind(scope, bufnr, handlers, overrides)
  assert(vim.api.nvim_buf_is_valid(bufnr), 'keymaps.bind: invalid buffer')
  for _, entry in ipairs(M.resolve(scope, overrides)) do
    local handler = handlers[entry.spec.action]
    assert(
      handler,
      ('keymaps.bind: scope `%s` has no handler for `%s`'):format(scope, entry.spec.action)
    )
    for _, lhs in ipairs(entry.lhs) do
      vim.keymap.set(entry.spec.mode, lhs, handler, {
        buffer = bufnr,
        desc = 'dblens: ' .. entry.spec.desc,
        nowait = true,
        silent = true,
      })
    end
  end
end

--- Bindings grouped for the help overlay, preserving declaration order.
---@return { group: string, items: { lhs: string, desc: string, mode: string }[] }[]
function M.help_sections(scope, overrides)
  local order, sections = {}, {}
  for _, entry in ipairs(M.resolve(scope, overrides)) do
    local group = entry.spec.group
    if not sections[group] then
      sections[group] = {}
      order[#order + 1] = group
    end
    table.insert(sections[group], {
      lhs = table.concat(entry.lhs, ' / '),
      desc = entry.spec.desc,
      mode = type(entry.spec.mode) == 'table' and table.concat(entry.spec.mode, '')
        or entry.spec.mode,
    })
  end
  local out = {}
  for _, group in ipairs(order) do
    out[#out + 1] = { group = group, items = sections[group] }
  end
  return out
end

return M
