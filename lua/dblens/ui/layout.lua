--- The dblens window layout: a sidebar, a SQL editor and a results grid.
---
--- Everything lives in a dedicated tabpage. That is what makes `:DbLensClose` exact rather than
--- best-effort — the user's own windows are never touched, resized or reordered, so closing is
--- just closing the tab.
local api = vim.api

local M = {}

---@class dblens.Layout
---@field tabpage integer
---@field wins table<string, integer>
---@field bufs table<string, integer>

local PANES = { 'sidebar', 'editor', 'results' }

--- No slashes: the default tabline shows a buffer name's tail, and `dblens://schema` renders as
--- the meaningless `d//schema`.
local BUF_NAMES = {
  sidebar = 'dblens: schema',
  editor = 'dblens: query.sql',
  results = 'dblens: results',
}

local function make_buffer(pane)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = pane == 'editor' and 'sql' or ('dblens' .. pane)
  if pane ~= 'editor' then
    vim.bo[buf].modifiable = false
  end
  -- A stale buffer of the same name survives a crash; take the name back rather than failing.
  pcall(api.nvim_buf_set_name, buf, BUF_NAMES[pane])
  return buf
end

local function configure_window(win, pane, options)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.spell = false
  wo.list = false
  wo.wrap = false
  wo.cursorline = pane ~= 'editor'
  -- The row under the cursor is the only row marker in the data panes, so it stays on even when
  -- the pane is not focused.
  wo.cursorlineopt = pane ~= 'editor' and 'line' or 'both'
  wo.winhighlight = require('dblens.ui.highlights').winhighlight(options.ui.statusline)
  if options.ui.statusline then
    -- The winbar already names the pane, so the line between two panes is a rule rather than a
    -- repeated `dblens: query.sql`. Window-local, so it never touches the user's own windows.
    wo.statusline = "%{repeat('─', winwidth(0))}"
  end
  -- `~` past the last line reads as clutter in a data pane.
  wo.fillchars = 'eob: '
  wo.winfixwidth = pane == 'sidebar'
  wo.winfixheight = pane == 'results'
  if not options.ui.winbar then
    wo.winbar = ''
  end
end

--- The sidebar yields down to this before the grid is allowed to take the rest.
local MIN_SIDEBAR = 20
--- Columns the grid keeps before the sidebar starts giving any back.
local MIN_MAIN = 50

--- Sidebar width for a terminal this wide.
---
--- The configured width is a preference, not a demand: 34 columns of tree beside a 45-column
--- grid is unreadable on an 80-column terminal, so the sidebar yields once the grid would drop
--- below `MIN_MAIN`. On anything roomier the configured width is honoured exactly.
---@param configured integer
---@param total_columns integer
---@return integer  -- at least 1, never wider than the screen
function M.sidebar_width(configured, total_columns)
  assert(type(configured) == 'number' and configured > 0, 'layout.sidebar_width: bad width')
  assert(type(total_columns) == 'number', 'layout.sidebar_width: needs the screen width')
  local width = math.min(configured, math.max(MIN_SIDEBAR, total_columns - MIN_MAIN))
  return math.max(1, math.min(width, math.max(1, total_columns - 1)))
end

--- Rows for the results pane out of the rows the two stacked panes share.
---@param total_rows integer
---@param share number  -- fraction strictly between 0 and 1
---@return integer  -- at least 1, and always leaves the editor at least 1
function M.results_height(total_rows, share)
  assert(type(total_rows) == 'number', 'layout.results_height: needs the rows available')
  assert(type(share) == 'number' and share > 0 and share < 1, 'layout.results_height: bad share')
  if total_rows < 2 then
    return 1
  end
  -- Below three rows the grid cannot show a header, its rule and one row of data.
  local height = math.max(math.floor(total_rows * share), math.min(3, total_rows - 1))
  return math.max(1, math.min(height, total_rows - 1))
end

--- Build the three-pane layout in a new tabpage.
---@param options table
---@return dblens.Layout
function M.open(options)
  local bufs = {}
  for _, pane in ipairs(PANES) do
    bufs[pane] = make_buffer(pane)
  end

  vim.cmd('tabnew')
  local placeholder = api.nvim_get_current_buf()
  local tabpage = api.nvim_get_current_tabpage()

  local wins = {}
  wins.editor = api.nvim_get_current_win()
  api.nvim_win_set_buf(wins.editor, bufs.editor)

  vim.cmd('belowright split')
  wins.results = api.nvim_get_current_win()
  api.nvim_win_set_buf(wins.results, bufs.results)

  -- `topleft`/`botright` make the sidebar span the full tab height, beside both other panes.
  vim.cmd(options.ui.sidebar.position == 'right' and 'botright vsplit' or 'topleft vsplit')
  wins.sidebar = api.nvim_get_current_win()
  api.nvim_win_set_buf(wins.sidebar, bufs.sidebar)

  if api.nvim_buf_is_valid(placeholder) and placeholder ~= bufs.editor then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end

  for _, pane in ipairs(PANES) do
    configure_window(wins[pane], pane, options)
  end

  local layout = { tabpage = tabpage, wins = wins, bufs = bufs }
  M.resize(layout, options)
  return layout
end

--- Apply the configured sidebar width and results share to the space actually available.
function M.resize(layout, options)
  if not M.is_open(layout) then
    return
  end
  api.nvim_win_set_width(
    layout.wins.sidebar,
    M.sidebar_width(options.ui.sidebar.width, vim.o.columns)
  )
  local total = api.nvim_win_get_height(layout.wins.editor)
    + api.nvim_win_get_height(layout.wins.results)
  api.nvim_win_set_height(layout.wins.results, M.results_height(total, options.ui.results.height))
end

---@return boolean
function M.is_open(layout)
  if not layout or not api.nvim_tabpage_is_valid(layout.tabpage) then
    return false
  end
  for _, pane in ipairs(PANES) do
    if not api.nvim_win_is_valid(layout.wins[pane]) then
      return false
    end
  end
  return true
end

--- Which pane the cursor is in, or nil when it is somewhere else entirely.
---@return 'sidebar'|'editor'|'results'|nil
function M.current_pane(layout)
  if not layout then
    return nil
  end
  local win = api.nvim_get_current_win()
  for _, pane in ipairs(PANES) do
    if layout.wins[pane] == win then
      return pane
    end
  end
  return nil
end

--- Move the cursor to a pane. Returns false when that pane is gone.
---@param pane 'sidebar'|'editor'|'results'
function M.focus(layout, pane)
  local win = layout and layout.wins[pane]
  if not win or not api.nvim_win_is_valid(win) then
    return false
  end
  api.nvim_set_current_win(win)
  return true
end

--- Drop every dblens window but one, for the case where closing the tabpage is not possible.
local function collapse_windows(layout)
  local wins = {}
  for _, pane in ipairs(PANES) do
    local win = layout.wins[pane]
    if api.nvim_win_is_valid(win) then
      wins[#wins + 1] = win
    end
  end
  for index = 2, #wins do
    pcall(api.nvim_win_close, wins[index], true)
  end
end

--- Close the layout, restoring the user's windows by simply dropping the tabpage.
---
--- When dblens owns the only tabpage there is nothing to close back to, so the panes are
--- collapsed to one window instead of leaving a three-way split of dead scratch buffers.
function M.close(layout)
  if not layout then
    return
  end
  if api.nvim_tabpage_is_valid(layout.tabpage) then
    -- Leaving the tab first avoids a redraw into a half-closed layout.
    pcall(function()
      if #api.nvim_list_tabpages() > 1 then
        api.nvim_set_current_tabpage(layout.tabpage)
        vim.cmd('tabclose')
        return
      end
      collapse_windows(layout)
    end)
  end
  for _, buf in pairs(layout.bufs) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

--- Replace a managed buffer's contents, handling the non-modifiable panes.
---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
  assert(api.nvim_buf_is_valid(buf), 'layout.set_lines: invalid buffer')
  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = was_modifiable
  vim.bo[buf].modified = false
end

M.PANES = PANES
return M
