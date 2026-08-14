--- The `?` overlay. Rendered from the keymap registry, so it always matches what is bound.
---
--- Reflows into two columns when the bindings would not fit the screen height, because a help
--- panel whose last section is below the fold is worse than no help panel.
local float = require('dblens.ui.float')
local keymaps = require('dblens.keymaps')

local M = {}

local TITLE = { sidebar = 'Schema', results = 'Results', editor = 'SQL editor' }
local GUTTER = 4

---@class dblens.HelpBlock
---@field heading string
---@field rows { left: string, right: string }[]

--- Gather every binding that applies in a scope, as headed blocks.
---@return dblens.HelpBlock[]
function M.blocks(scope, options)
  local out = {}
  local function collect(source_scope, overrides)
    for _, group in ipairs(keymaps.help_sections(source_scope, overrides)) do
      local rows = {}
      for _, item in ipairs(group.items) do
        rows[#rows + 1] = { left = item.lhs, right = item.desc }
      end
      out[#out + 1] = { heading = group.group, rows = rows }
    end
  end
  collect(scope, options.keymaps[scope])
  collect('global', options.keymaps.global)
  return out
end

--- Render blocks into lines, recording which lines are headings.
---@return string[] lines, table<integer, boolean> heading_lines (0-based)
local function render_column(blocks)
  local lines, headings = {}, {}
  for _, block in ipairs(blocks) do
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    headings[#lines] = true
    lines[#lines + 1] = block.heading
    for _, line in ipairs(float.align(block.rows)) do
      lines[#lines + 1] = line
    end
  end
  return lines, headings
end

local function height_of(blocks)
  local total = 0
  for index, block in ipairs(blocks) do
    total = total + #block.rows + 1 + (index > 1 and 1 or 0)
  end
  return total
end

--- Split blocks into two balanced columns, keeping declaration order down each column.
local function split_blocks(blocks)
  local target, running, at = height_of(blocks) / 2, 0, #blocks
  for index, block in ipairs(blocks) do
    running = running + #block.rows + 2
    if running >= target then
      at = index
      break
    end
  end
  local left, right = {}, {}
  for index, block in ipairs(blocks) do
    table.insert(index <= at and left or right, block)
  end
  return left, right
end

--- Lay blocks out in one or two columns depending on the space available.
---@return string[] lines, table<integer, boolean> heading_lines
function M.layout(blocks, available_height)
  local single, headings = render_column(blocks)
  if #single <= available_height or #blocks < 4 then
    return single, headings
  end

  local left_blocks, right_blocks = split_blocks(blocks)
  local left, left_headings = render_column(left_blocks)
  local right, right_headings = render_column(right_blocks)

  local width = 0
  for _, line in ipairs(left) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local lines, merged = {}, {}
  for index = 1, math.max(#left, #right) do
    local a, b = left[index] or '', right[index] or ''
    local pad = string.rep(' ', width - vim.fn.strdisplaywidth(a) + GUTTER)
    lines[index] = vim.trim(a .. pad .. b) == '' and '' or (a .. pad .. b)
    if left_headings[index - 1] or right_headings[index - 1] then
      merged[index - 1] = true
    end
  end
  return lines, merged
end

--- Show the overlay for the pane the user is in.
---@param state dblens.State
---@param scope 'sidebar'|'results'|'editor'
function M.show(state, scope)
  local available = math.floor(vim.o.lines * state.options.ui.float.max_height) - 2
  local lines, headings = M.layout(M.blocks(scope, state.options), available)

  local popup = float.open(lines, state.options, {
    title = ('dblens - %s'):format(TITLE[scope] or scope),
    footer = 'q close',
    min_width = 46,
  })

  local namespace = vim.api.nvim_create_namespace('dblens.help')
  for index, line in ipairs(lines) do
    if headings[index - 1] then
      vim.api.nvim_buf_set_extmark(popup.buf, namespace, index - 1, 0, {
        end_col = #line,
        hl_group = 'DbLensTitle',
      })
    end
    -- Dim-highlight each key column so the bindings read before the descriptions.
    for from, key in line:gmatch('()  (%S+)  ') do
      pcall(vim.api.nvim_buf_set_extmark, popup.buf, namespace, index - 1, from + 1, {
        end_col = from + 1 + #key,
        hl_group = 'DbLensAccent',
      })
    end
  end
  return popup
end

return M
