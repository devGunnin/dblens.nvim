--- Icon sets, degrading cleanly.
---
--- Three complete sets rather than per-glyph fallbacks, so switching between them never shifts
--- the layout. The default is plain Unicode that renders in any terminal font; `'nerd'` opts in
--- to Nerd Font glyphs, which live in the private use area and show as boxes without that font.
local M = {}

--- Nerd Font glyphs, written as UTF-8 byte escapes: private-use codepoints do not survive every
--- editor and pipeline as literal characters.
local NERD = {
  database = '\239\135\128', -- nf-fa-database
  schema = '\239\129\187', -- nf-fa-folder
  table = '\239\131\142', -- nf-fa-table
  view = '\239\129\174', -- nf-fa-eye
  column = '\239\131\155', -- nf-fa-columns
  key = '\239\130\132', -- nf-fa-key
  link = '\239\131\129', -- nf-fa-link
  index = '\239\128\186', -- nf-fa-list
  constraint = '\239\132\178', -- nf-fa-shield
  expanded = '▾',
  collapsed = '▸',
  leaf = ' ',
  running = '\239\132\144', -- nf-fa-spinner
  error = '\239\128\141', -- nf-fa-times
  lock = '\239\128\163', -- nf-fa-lock
  transaction = '\239\131\172', -- nf-fa-exchange
}

--- Default: geometric symbols present in essentially every monospace font.
local UNICODE = {
  database = '◈',
  schema = '◇',
  table = '▦',
  view = '◫',
  column = '▪',
  key = '◆',
  link = '↗',
  index = '≡',
  constraint = '⊞',
  expanded = '▾',
  collapsed = '▸',
  leaf = ' ',
  running = '◌',
  error = '✗',
  lock = '⊘',
  transaction = '⧗',
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

--- Devicons, when installed, gives a per-filetype glyph for the database file.
local function devicon()
  local ok, devicons = pcall(require, 'nvim-web-devicons')
  if not ok then
    return nil
  end
  return devicons.get_icon('db.sqlite3', 'sqlite3', { default = false })
end

--- Resolve the configured icon set.
---@param setting boolean|string  true | false | 'nerd'
---@return table<string, string>
function M.get(setting)
  if setting == false then
    return vim.deepcopy(PLAIN)
  end
  if setting == 'nerd' then
    local set = vim.deepcopy(NERD)
    set.database = devicon() or set.database
    return set
  end
  return vim.deepcopy(UNICODE)
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
