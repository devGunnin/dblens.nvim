--- Empty-state panels: what a pane shows when it has nothing to show.
---
--- A pane with nothing in it is where a new user spends their first minute, so it says what is
--- missing and which key fixes it. Callers read the key from `keymaps.lhs_for`, never a literal,
--- so a remap changes what the user is told.
local M = {}

---@class dblens.Hint
---@field key string?   -- the binding to press, omitted for a plain line
---@field text string
---@field hl string?    -- defaults to DbLensDim

---@class dblens.Mark
---@field line integer  -- 0-based
---@field col integer
---@field end_col integer
---@field hl string

--- Lay out a heading and its hints, aligned on the key column.
---@param heading string
---@param hints dblens.Hint[]
---@param heading_hl string?
---@return string[] lines, dblens.Mark[] marks
function M.panel(heading, hints, heading_hl)
  assert(type(heading) == 'string' and heading ~= '', 'empty.panel: needs a heading')
  assert(vim.islist(hints), 'empty.panel: hints must be a list')

  local lines = { '', '  ' .. heading }
  local marks = { { line = 1, col = 0, end_col = #lines[2], hl = heading_hl or 'DbLensDim' } }
  if #hints == 0 then
    return lines, marks
  end

  local key_width = 0
  for _, hint in ipairs(hints) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(hint.key or ''))
  end

  lines[#lines + 1] = ''
  for _, hint in ipairs(hints) do
    local key = hint.key or ''
    local prefix = '  ' .. key .. string.rep(' ', key_width - vim.fn.strdisplaywidth(key) + 2)
    local line = prefix .. hint.text
    lines[#lines + 1] = line
    local at = #lines - 1
    if hint.key then
      marks[#marks + 1] = { line = at, col = 2, end_col = 2 + #key, hl = 'DbLensAccent' }
    end
    marks[#marks + 1] = { line = at, col = #prefix, end_col = #line, hl = hint.hl or 'DbLensDim' }
  end
  return lines, marks
end

return M
