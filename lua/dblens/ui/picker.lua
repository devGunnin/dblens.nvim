--- A self-contained fuzzy picker, plus the choosers built on it.
---
--- Filtering uses `matchfuzzypos`, which ships with Neovim, so table search is genuinely fuzzy
--- without depending on any picker plugin. Two floats: a list, and a prompt below it.
local float = require('dblens.ui.float')
local history = require('dblens.history')

local api = vim.api

local M = {}

local NAMESPACE = api.nvim_create_namespace('dblens.picker')

---@class dblens.PickerItem
---@field text string    -- what is matched and shown
---@field detail string? -- dimmed right-hand text
---@field value any

--- Rank items against a query, keeping input order when the query is empty.
---@return { item: dblens.PickerItem, positions: integer[] }[]
local function filter(items, query)
  if query == '' then
    local out = {}
    for _, item in ipairs(items) do
      out[#out + 1] = { item = item, positions = {} }
    end
    return out
  end

  local strings, pending = {}, {}
  for index, item in ipairs(items) do
    strings[index] = item.text
    pending[item.text] = pending[item.text] or {}
    table.insert(pending[item.text], index)
  end

  local matched, positions = unpack(vim.fn.matchfuzzypos(strings, query))
  local out = {}
  for rank, text in ipairs(matched) do
    local queue = pending[text]
    local index = queue and table.remove(queue, 1)
    if index then
      out[#out + 1] = { item = items[index], positions = positions[rank] or {} }
    end
  end
  return out
end

local Picker = {}
Picker.__index = Picker

function Picker:render()
  local lines = {}
  for index, entry in ipairs(self.matches) do
    local detail = entry.item.detail and ('  ' .. entry.item.detail) or ''
    lines[index] = ('  %s%s'):format(entry.item.text, detail)
  end
  if #lines == 0 then
    lines = { '  no matches' }
  end
  vim.bo[self.list_buf].modifiable = true
  api.nvim_buf_set_lines(self.list_buf, 0, -1, false, lines)
  vim.bo[self.list_buf].modifiable = false

  api.nvim_buf_clear_namespace(self.list_buf, NAMESPACE, 0, -1)
  for index, entry in ipairs(self.matches) do
    if entry.item.detail then
      local from = 2 + #entry.item.text
      api.nvim_buf_set_extmark(self.list_buf, NAMESPACE, index - 1, from, {
        end_col = #lines[index],
        hl_group = 'DbLensDim',
      })
    end
    -- `matchfuzzypos` gives character positions; the picker text is ASCII in practice, and an
    -- out-of-range column is skipped rather than raising.
    for _, position in ipairs(entry.positions) do
      pcall(api.nvim_buf_set_extmark, self.list_buf, NAMESPACE, index - 1, 2 + position, {
        end_col = 3 + position,
        hl_group = 'DbLensMatch',
      })
    end
  end
  if #self.matches > 0 then
    api.nvim_buf_set_extmark(self.list_buf, NAMESPACE, self.index - 1, 0, {
      end_row = self.index,
      hl_group = 'DbLensMatch',
      hl_eol = true,
      priority = 50,
    })
    if api.nvim_win_is_valid(self.list_win) then
      api.nvim_win_set_cursor(self.list_win, { self.index, 0 })
    end
  end
end

function Picker:move(delta)
  if #self.matches == 0 then
    return
  end
  self.index = (self.index + delta - 1) % #self.matches + 1
  self:render()
end

function Picker:update(query)
  self.matches = filter(self.items, query)
  self.index = 1
  self:render()
end

function Picker:close()
  if self.closed then
    return
  end
  self.closed = true
  for _, win in ipairs({ self.list_win, self.prompt_win }) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  for _, buf in ipairs({ self.list_buf, self.prompt_buf }) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function make_window(buf, config)
  local win = api.nvim_open_win(buf, false, config)
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = 'Normal:DbLensNormal,FloatBorder:DbLensBorder,FloatTitle:DbLensTitle'
  return win
end

--- Open the picker.
---
--- `on_alt` is a second thing the picked item can be used for, on its own key — how the history
--- and snippet pickers offer "run it now" without taking `<CR>` away from what it already does.
---@param state dblens.State
---@param opts { title: string, items: dblens.PickerItem[], on_choose: fun(value: any), on_alt: fun(value: any)?, choose_hint: string?, alt_hint: string? }
function M.select(state, opts)
  assert(vim.islist(opts.items), 'picker.select: items must be a list')
  assert(type(opts.on_choose) == 'function', 'picker.select: on_choose must be a function')
  assert(
    opts.on_alt == nil or type(opts.on_alt) == 'function',
    'picker.select: on_alt must be a function'
  )
  if #opts.items == 0 then
    require('dblens.app').notify('nothing to choose from')
    return
  end

  local options = state.options
  local width = math.max(40, math.min(math.floor(vim.o.columns * 0.6), 100))
  local height = math.max(1, math.min(#opts.items, math.floor(vim.o.lines * 0.4)))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local self = setmetatable({ items = opts.items, matches = {}, index = 1, closed = false }, Picker)

  self.list_buf = api.nvim_create_buf(false, true)
  vim.bo[self.list_buf].bufhidden = 'wipe'
  self.list_win = make_window(self.list_buf, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = options.ui.border,
    title = ' ' .. opts.title .. ' ',
    title_pos = 'center',
  })

  self.prompt_buf = api.nvim_create_buf(false, true)
  vim.bo[self.prompt_buf].bufhidden = 'wipe'
  vim.bo[self.prompt_buf].buftype = 'prompt'
  vim.fn.prompt_setprompt(self.prompt_buf, '  ')
  local footer = (' <CR> %s · '):format(opts.choose_hint or 'open')
    .. (opts.on_alt and ('<C-r> %s · '):format(opts.alt_hint or 'alternate') or '')
    .. '<C-n>/<C-p> move · <Esc> cancel '
  self.prompt_win = make_window(self.prompt_buf, {
    relative = 'editor',
    width = width,
    height = 1,
    row = row + height + 2,
    col = col,
    style = 'minimal',
    border = options.ui.border,
    footer = footer,
    footer_pos = 'center',
  })

  self:update('')
  api.nvim_set_current_win(self.prompt_win)
  vim.cmd('startinsert')

  api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = self.prompt_buf,
    callback = function()
      local line = api.nvim_buf_get_lines(self.prompt_buf, 0, 1, false)[1] or ''
      self:update(vim.trim(line:sub(3)))
    end,
  })

  --- Close first, then hand the picked value to `handler` on the next tick, so the handler can
  --- open a float or focus a pane without racing this picker's own teardown.
  local function accept(handler)
    local entry = self.matches[self.index]
    self:close()
    vim.cmd('stopinsert')
    if entry then
      vim.schedule(function()
        handler(entry.item.value)
      end)
    end
  end
  local function cancel()
    self:close()
    vim.cmd('stopinsert')
  end

  local map = function(lhs, fn, modes)
    vim.keymap.set(
      modes or { 'i', 'n' },
      lhs,
      fn,
      { buffer = self.prompt_buf, nowait = true, silent = true }
    )
  end
  map('<CR>', function()
    accept(opts.on_choose)
  end)
  if opts.on_alt then
    local function alternate()
      accept(opts.on_alt)
    end
    -- `<C-CR>` is the natural key but many terminals do not send it; `<C-r>` is the one that
    -- always arrives, and inside a fuzzy prompt its register insert is no loss.
    map('<C-r>', alternate)
    map('<C-CR>', alternate)
  end
  map('<Esc>', cancel)
  map('<C-c>', cancel)
  map('q', cancel, { 'n' })
  map('<C-n>', function()
    self:move(1)
  end)
  map('<C-p>', function()
    self:move(-1)
  end)
  map('<Down>', function()
    self:move(1)
  end)
  map('<Up>', function()
    self:move(-1)
  end)

  api.nvim_create_autocmd('WinLeave', {
    buffer = self.prompt_buf,
    once = true,
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  return self
end

-- ---------------------------------------------------------------------------
-- the choosers

--- Entries that are an action rather than a connection. Identity, not text, decides which was
--- picked, so a database that happens to be named `Rescan` still connects.
local DISCOVER = { action = 'discover' }
local ADD = { action = 'add' }

--- Pick a connection.
---@param on_choose fun(spec: dblens.ConnectionSpec)?
function M.connections(state, on_choose)
  local items = {}
  for _, spec in ipairs(state.specs) do
    local adapter = require('dblens.adapters').get(spec.kind)
    items[#items + 1] = {
      text = spec.name,
      detail = ('%s  %s%s%s'):format(
        adapter and adapter.label or spec.kind,
        adapter and adapter.describe(spec) or '',
        spec.read_only and '  read-only' or '',
        spec.source == 'discovered' and '  discovered' or ''
      ),
      value = spec,
    }
  end
  items[#items + 1] =
    { text = 'Discover…', detail = 'scan this project for databases', value = DISCOVER }
  M.select(state, {
    title = 'Connections',
    items = items,
    on_choose = function(value)
      if value == DISCOVER then
        require('dblens.app').discover()
        return
      end
      if on_choose then
        on_choose(value)
        return
      end
      require('dblens.app').connect(value.name)
    end,
  })
end

--- Offer what discovery found in the workspace.
---
--- Candidates come first and the picker starts on the first one, so the single obvious candidate
--- is preselected — but nothing connects until the user confirms it, and what connects opens
--- LOCKED. `Add manually…` and `Rescan` are the two ways out.
---@param state dblens.State
---@param candidates dblens.Candidate[]
---@param report dblens.DiscoveryReport
function M.discovered(state, candidates, report)
  assert(vim.islist(candidates) and #candidates > 0, 'picker.discovered: needs candidates')
  local items = {}
  for _, candidate in ipairs(candidates) do
    items[#items + 1] = { text = candidate.name, detail = candidate.detail, value = candidate }
  end
  items[#items + 1] = { text = 'Add manually…', detail = 'the :DbLensAdd form', value = ADD }
  items[#items + 1] =
    { text = 'Rescan', detail = 'look through the project again', value = DISCOVER }

  M.select(state, {
    title = ('Discovered in %s'):format(vim.fn.fnamemodify(report.root, ':~')),
    items = items,
    on_choose = function(value)
      local app = require('dblens.app')
      if value == DISCOVER then
        app.discover()
        return
      end
      if value == ADD then
        require('dblens.ui.form').add(state.options)
        return
      end
      app.connect_discovered(value)
    end,
  })
end

--- Fuzzy-find a table across every loaded schema.
---@param on_choose fun(relation: dblens.Relation)?  -- browses the table by default
function M.tables(state, on_choose)
  local session = state.session
  if not session then
    require('dblens.app').notify('not connected')
    return
  end
  local items = {}
  for _, relation in ipairs(session.catalog:all_relations()) do
    items[#items + 1] = {
      text = relation.schema and (relation.schema .. '.' .. relation.name) or relation.name,
      detail = relation.kind,
      value = relation,
    }
  end
  M.select(state, {
    title = 'Tables',
    items = items,
    on_choose = on_choose or function(relation)
      require('dblens.app').open_relation(relation)
    end,
  })
end

local function put_in_editor(state, sql)
  local buf = state.layout.bufs.editor
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local at = #lines
  if vim.trim(lines[at] or '') ~= '' then
    at = at + 1
  end
  api.nvim_buf_set_lines(buf, at - 1, -1, false, vim.split(sql, '\n', { plain = true }))
  require('dblens.ui.layout').focus(state.layout, 'editor')
end

--- Run a picked statement immediately.
---
--- Through `app.run_sql`, never `session:run_script` — so a stored DELETE re-run from the picker
--- meets the same classification, the same read-only refusal and the same confirmation float as
--- one typed into the editor. The picker is a shortcut to the editor's <CR>, not around it.
local function run_now(label)
  return function(sql)
    require('dblens.app').run_sql(sql, { label = label })
  end
end

--- Browse query history for the current connection.
function M.history(state)
  local session = state.session
  local entries = history.entries(state.history, session and session.spec.name or nil)
  local items = {}
  for _, entry in ipairs(entries) do
    items[#items + 1] = {
      text = (entry.sql:gsub('%s+', ' ')),
      detail = os.date('%Y-%m-%d %H:%M', entry.at),
      value = entry.sql,
    }
  end
  M.select(state, {
    title = 'History',
    items = items,
    choose_hint = 'to editor',
    alt_hint = 'run',
    on_choose = function(sql)
      put_in_editor(state, sql)
    end,
    on_alt = run_now('history'),
  })
end

--- Browse saved snippets.
function M.snippets(state)
  local items = {}
  for _, snippet in ipairs(history.snippets(state.history)) do
    items[#items + 1] =
      { text = snippet.name, detail = (snippet.sql:gsub('%s+', ' ')), value = snippet.sql }
  end
  M.select(state, {
    title = 'Snippets',
    items = items,
    choose_hint = 'to editor',
    alt_hint = 'run',
    on_choose = function(sql)
      put_in_editor(state, sql)
    end,
    on_alt = run_now('snippet'),
  })
end

--- Save SQL as a named snippet.
function M.save_snippet(state, sql)
  local app = require('dblens.app')
  if vim.trim(sql or '') == '' then
    app.notify('nothing to save')
    return
  end
  vim.ui.input({ prompt = 'Snippet name: ' }, function(name)
    if not name or vim.trim(name) == '' then
      return
    end
    local ok, err = history.save_snippet(state.history, vim.trim(name), sql)
    if not ok then
      app.error(err)
      return
    end
    history.save(state.history, state.options)
    app.notify(('saved snippet `%s`'):format(vim.trim(name)))
  end)
end

--- Show the changes queued by the open transaction.
function M.pending(state)
  local session = state.session
  if not session or not session.txn:is_active() then
    require('dblens.app').notify('no transaction is open')
    return
  end
  local lines = {}
  for index, change in ipairs(session.txn.pending) do
    lines[#lines + 1] = ('%d. %s'):format(index, change.summary)
    lines[#lines + 1] = '   ' .. change.sql
  end
  if #lines == 0 then
    lines = { 'no changes queued yet' }
  end
  float.open(lines, state.options, {
    title = ('Pending - %d change(s)'):format(session.txn:count()),
    footer = '<leader>dC commit · <leader>dR roll back · q close',
    filetype = 'sql',
    min_width = 60,
  })
end

return M
