--- Icon set, degrading cleanly when icons are switched off.
---
--- Two complete sets rather than per-glyph fallbacks: `ui.icons = false` gives an ASCII-safe
--- layout with the same column geometry, so nothing shifts when a user turns icons off.
local M = {}

local NERD = {
  database = '',
  schema = '',
  table = '',
  view = '',
  column = '',
  key = '',
  link = '',
  index = '',
  constraint = '',
  expanded = '',
  collapsed = '',
  leaf = ' ',
  running = '',
  error = '',
  lock = '',
  transaction = '',
}

local PLAIN = {
  database = 'DB',
  schema = 'S',
  table = 'T',
  view = 'V',
  column = '-',
  key = '*',
  link = '>',
  index = 'I',
  constraint = 'C',
  expanded = 'v',
  collapsed = '>',
  leaf = ' ',
  running = '*',
  error = '!',
  lock = 'RO',
  transaction = 'TX',
}

--- Devicons, when installed, gives a per-filetype glyph for the sqlite file.
local function devicon()
  local ok, devicons = pcall(require, 'nvim-web-devicons')
  if not ok then
    return nil
  end
  local glyph = devicons.get_icon('db.sqlite3', 'sqlite3', { default = false })
  return glyph
end

---@param enabled boolean
---@return table<string, string>
function M.get(enabled)
  if not enabled then
    return vim.deepcopy(PLAIN)
  end
  local set = vim.deepcopy(NERD)
  set.database = devicon() or set.database
  return set
end

--- Node kind -> icon key, so the sidebar does not carry a mapping of its own.
M.NODE = {
  connection = 'database',
  schema = 'schema',
  table = 'table',
  view = 'view',
  column = 'column',
  folder = 'index',
  index = 'index',
  constraint = 'constraint',
}

return M
