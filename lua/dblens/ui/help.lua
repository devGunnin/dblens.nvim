--- The `?` overlay. Rendered from the keymap registry, so it always matches what is bound.
---
--- Reflows into two columns when the bindings would not fit the screen height, because a help
--- panel whose last section is below the fold is worse than no help panel.
local float = require('dblens.ui.float')
local keymaps = require('dblens.keymaps')

local M = {}

local TITLE =
  { sidebar = 'Schema', results = 'Results', editor = 'SQL editor', connections = 'Connections' }
local GUTTER = 4
--- Screen cells left around the panel, so it reads as an overlay rather than a takeover.
local MARGIN = 6

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

---@class dblens.HeadingSpan
---@field line integer  -- 0-based
---@field col integer
---@field end_col integer

--- Render blocks into lines, recording where each heading sits.
---
--- A span, not a flag: a heading in one column used to mark the whole merged line, which printed
--- whatever the other column happened to hold on that row as a heading too.
---@param spacer boolean  -- keep the blank line between blocks
---@return string[] lines, dblens.HeadingSpan[] headings
local function render_column(blocks, spacer)
  local lines, headings = {}, {}
  for _, block in ipairs(blocks) do
    if spacer and #lines > 0 then
      lines[#lines + 1] = ''
    end
    headings[#headings + 1] = { line = #lines, col = 0, end_col = #block.heading }
    lines[#lines + 1] = block.heading
    for _, line in ipairs(float.align(block.rows)) do
      lines[#lines + 1] = line
    end
  end
  return lines, headings
end

--- The cut that leaves the two columns as even as possible. The previous rule walked to the
--- first block past half the total height, which for six blocks left one column two rows longer
--- than the screen even though a better cut fitted.
---@return dblens.HelpBlock[] left, dblens.HelpBlock[] right
local function split_blocks(blocks, spacer)
  local best, best_cost = 1, math.huge
  for at = 1, #blocks - 1 do
    local left, right = {}, {}
    for index, block in ipairs(blocks) do
      table.insert(index <= at and left or right, block)
    end
    local cost = math.max(#render_column(left, spacer), #render_column(right, spacer))
    if cost < best_cost then
      best, best_cost = at, cost
    end
  end
  local left, right = {}, {}
  for index, block in ipairs(blocks) do
    table.insert(index <= best and left or right, block)
  end
  return left, right
end

--- Merge two rendered columns side by side, shifting the right column's heading spans.
local function join_columns(left, left_headings, right, right_headings)
  local width = 0
  for _, line in ipairs(left) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local lines, offsets = {}, {}
  for index = 1, math.max(#left, #right) do
    local a, b = left[index] or '', right[index] or ''
    local pad = string.rep(' ', width - vim.fn.strdisplaywidth(a) + GUTTER)
    -- Padding is spaces, so the right column starts at exactly this many bytes in.
    offsets[index - 1] = #a + #pad
    lines[index] = vim.trim(a .. pad .. b) == '' and '' or (a .. pad .. b)
  end

  local merged = {}
  for _, span in ipairs(left_headings) do
    merged[#merged + 1] = span
  end
  for _, span in ipairs(right_headings) do
    local shift = offsets[span.line] or 0
    merged[#merged + 1] =
      { line = span.line, col = span.col + shift, end_col = span.end_col + shift }
  end
  return lines, merged
end

local function two_columns(blocks, spacer)
  local left_blocks, right_blocks = split_blocks(blocks, spacer)
  local left, left_headings = render_column(left_blocks, spacer)
  local right, right_headings = render_column(right_blocks, spacer)
  return join_columns(left, left_headings, right, right_headings)
end

local function widest(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

--- Lay blocks out in the space available, tightening until they fit.
---
--- A help panel whose last section is below the fold is worse than no help panel — and one whose
--- descriptions are cut off at the right edge is no better, which is what two columns do on an
--- 80-column terminal. So each candidate is checked against BOTH dimensions and the first that
--- fits wins; when none does, the single narrow column is chosen, because a panel that scrolls
--- down still shows every binding in full.
---@param available_height integer
---@param available_width integer?  -- unlimited when omitted
---@return string[] lines, dblens.HeadingSpan[] headings, boolean fits
function M.layout(blocks, available_height, available_width)
  assert(vim.islist(blocks), 'help.layout: expected a block list')
  assert(type(available_height) == 'number', 'help.layout: needs the rows available')
  local width_budget = available_width or math.huge

  local candidates = {}
  local function add(lines, headings)
    candidates[#candidates + 1] = { lines = lines, headings = headings }
  end
  add(render_column(blocks, true))
  if #blocks >= 2 then
    add(two_columns(blocks, true))
    add(two_columns(blocks, false))
  end
  add(render_column(blocks, false))

  for _, candidate in ipairs(candidates) do
    if #candidate.lines <= available_height and widest(candidate.lines) <= width_budget then
      return candidate.lines, candidate.headings, true
    end
  end
  local narrowest = candidates[#candidates]
  return narrowest.lines, narrowest.headings, false
end

--- Room the overlay may use on a screen this size.
---
--- It is a panel, not a popup: `ui.float.max_width` left a 100-column terminal too narrow for
--- two columns, so every binding scrolled on a screen with room to show them all.
---@param lines integer
---@param columns integer
---@return integer rows, integer columns
function M.budget(lines, columns)
  assert(type(lines) == 'number' and type(columns) == 'number', 'help.budget: needs the screen')
  return math.max(4, lines - MARGIN), math.max(30, columns - MARGIN)
end

--- Show the overlay for the pane the user is in.
---@param state dblens.State
---@param scope 'sidebar'|'results'|'editor'
function M.show(state, scope)
  local rows, columns = M.budget(vim.o.lines, vim.o.columns)
  local lines, headings, fits = M.layout(M.blocks(scope, state.options), rows, columns)

  local popup = float.open(lines, state.options, {
    title = ('dblens - %s'):format(TITLE[scope] or scope),
    footer = fits and 'q close' or 'j/k scroll · q close',
    min_width = 46,
    max_width = columns,
    max_height = rows,
  })

  local namespace = vim.api.nvim_create_namespace('dblens.help')
  for _, span in ipairs(headings) do
    pcall(vim.api.nvim_buf_set_extmark, popup.buf, namespace, span.line, span.col, {
      end_col = span.end_col,
      hl_group = 'DbLensTitle',
    })
  end
  for index, line in ipairs(lines) do
    -- Highlight each key column so the bindings read before the descriptions.
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
