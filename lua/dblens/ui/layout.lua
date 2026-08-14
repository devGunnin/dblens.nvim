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
  -- `~` past the last line reads as clutter in a data pane.
  wo.fillchars = 'eob: '
  wo.winfixwidth = pane == 'sidebar'
  wo.winfixheight = pane == 'results'
  if not options.ui.winbar then
    wo.winbar = ''
  end
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

--- Apply the configured sidebar width and results share.
function M.resize(layout, options)
  if not M.is_open(layout) then
    return
  end
  api.nvim_win_set_width(layout.wins.sidebar, options.ui.sidebar.width)
  local total = api.nvim_win_get_height(layout.wins.editor)
    + api.nvim_win_get_height(layout.wins.results)
  local results = math.max(3, math.floor(total * options.ui.results.height))
  api.nvim_win_set_height(layout.wins.results, results)
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

--- Close the layout, restoring the user's windows by simply dropping the tabpage.
function M.close(layout)
  if not layout then
    return
  end
  if api.nvim_tabpage_is_valid(layout.tabpage) then
    -- Leaving the tab first avoids a redraw into a half-closed layout.
    pcall(function()
      local count = #api.nvim_list_tabpages()
      if count > 1 then
        api.nvim_set_current_tabpage(layout.tabpage)
        vim.cmd('tabclose')
      end
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
