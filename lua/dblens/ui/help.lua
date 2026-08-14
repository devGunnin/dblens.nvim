--- The `?` overlay. Rendered from the keymap registry, so it always matches what is bound.
local float = require('dblens.ui.float')
local keymaps = require('dblens.keymaps')

local M = {}

local TITLE = { sidebar = 'Schema', results = 'Results', editor = 'SQL editor' }

--- Build the help body for a scope, including the global bindings.
---@return string[] lines, { line: integer, hl: string }[] marks
function M.build(scope, options)
  local lines, marks = {}, {}
  local function heading(text)
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    lines[#lines + 1] = text
    marks[#marks + 1] = { line = #lines - 1, hl = 'DbLensTitle' }
  end

  local function section(source_scope, overrides)
    for _, group in ipairs(keymaps.help_sections(source_scope, overrides)) do
      heading(group.group)
      local pairs_list = {}
      for _, item in ipairs(group.items) do
        pairs_list[#pairs_list + 1] = { left = item.lhs, right = item.desc }
      end
      for _, line in ipairs(float.align(pairs_list)) do
        lines[#lines + 1] = line
      end
    end
  end

  section(scope, options.keymaps[scope])
  section('global', options.keymaps.global)
  return lines, marks
end

--- Show the overlay for the pane the user is in.
---@param state dblens.State
---@param scope 'sidebar'|'results'|'editor'
function M.show(state, scope)
  local lines, marks = M.build(scope, state.options)
  local popup = float.open(lines, state.options, {
    title = ('dblens - %s'):format(TITLE[scope] or scope),
    footer = 'q close',
    min_width = 46,
  })
  local namespace = vim.api.nvim_create_namespace('dblens.help')
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(popup.buf, namespace, mark.line, 0, {
      end_col = #lines[mark.line + 1],
      hl_group = mark.hl,
    })
  end
  -- Dim the key column so the descriptions read first.
  for index, line in ipairs(lines) do
    local key = line:match('^  (%S+)')
    if key then
      vim.api.nvim_buf_set_extmark(popup.buf, namespace, index - 1, 2, {
        end_col = 2 + #key,
        hl_group = 'DbLensAccent',
      })
    end
  end
  return popup
end

return M
