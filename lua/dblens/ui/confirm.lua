--- The preview-and-confirm gate.
---
--- Every write dblens generates is shown here first — the exact SQL, what identifies the row, and
--- the blast radius when the adapter can estimate it. Nothing reaches the database from this
--- module; it only decides whether the caller may proceed.
local float = require('dblens.ui.float')

local M = {}

---@class dblens.ConfirmSection
---@field heading string
---@field lines string[]
---@field hl string?

local function build_lines(sections)
  local lines, marks = {}, {}
  for index, section in ipairs(sections) do
    if index > 1 then
      lines[#lines + 1] = ''
    end
    lines[#lines + 1] = section.heading
    marks[#marks + 1] = { line = #lines - 1, hl = 'DbLensDim' }
    for _, text in ipairs(section.lines) do
      lines[#lines + 1] = '  ' .. text
      marks[#marks + 1] = { line = #lines - 1, hl = section.hl or 'DbLensNormal' }
    end
  end
  return lines, marks
end

--- Ask the operator to confirm a change.
---
--- `on_confirm` runs only on an explicit yes. Any other dismissal is a decline, and a declined
--- change is simply never applied — there is no implicit default.
---@param options table
---@param opts { title: string, sections: dblens.ConfirmSection[], danger: boolean? }
---@param on_confirm fun()
function M.ask(options, opts, on_confirm)
  assert(type(on_confirm) == 'function', 'confirm.ask: on_confirm must be a function')
  assert(vim.islist(opts.sections), 'confirm.ask: sections must be a list')

  local lines, marks = build_lines(opts.sections)
  local popup = float.open(lines, options, {
    title = opts.title,
    footer = opts.danger and 'y apply · n cancel · this cannot be undone'
      or 'y apply · n cancel',
    close_keys = { 'n', 'q', '<Esc>' },
    min_width = 50,
  })

  local namespace = vim.api.nvim_create_namespace('dblens.confirm')
  for _, mark in ipairs(marks) do
    local text = lines[mark.line + 1]
    vim.api.nvim_buf_set_extmark(
      popup.buf,
      namespace,
      mark.line,
      0,
      { end_col = #text, hl_group = mark.hl }
    )
  end

  local decided = false
  vim.keymap.set('n', 'y', function()
    -- One answer per prompt: `on_confirm` runs a change, and two of them would run it twice.
    if decided then
      return
    end
    decided = true
    popup.close()
    on_confirm()
  end, { buffer = popup.buf, nowait = true, silent = true, desc = 'dblens: apply' })

  return function()
    return decided
  end
end

--- Render a SQL statement across lines for a preview section.
---@param statement string
---@return string[]
function M.sql_lines(statement)
  local out = {}
  for line in tostring(statement):gmatch('[^\n]+') do
    out[#out + 1] = line
  end
  return #out > 0 and out or { statement }
end

return M
