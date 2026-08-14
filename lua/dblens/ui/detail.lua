--- Read-only popups: the row detail view and the DDL view.
local ddl_mod = require('dblens.ddl')
local export = require('dblens.export')
local float = require('dblens.ui.float')
local protocol = require('dblens.protocol')

local M = {}

--- Full contents of one row, with values shown raw rather than grid-truncated.
---@param state dblens.State
---@param row integer
function M.row(state, row)
  local result = state.grid.result
  assert(result and result.rows[row], 'detail.row: no such row')

  local lines = export.row_lines(result.columns, result.rows[row])
  local popup = float.open(lines, state.options, {
    title = ('Row %d of %d'):format(row, #result.rows),
    footer = 'q close',
    min_width = 40,
  })

  local namespace = vim.api.nvim_create_namespace('dblens.detail')
  local width = 0
  for _, name in ipairs(result.columns) do
    width = math.max(width, vim.fn.strdisplaywidth(name))
  end
  for index, name in ipairs(result.columns) do
    local line = lines[index]
    if line and line:sub(1, #name) == name then
      vim.api.nvim_buf_set_extmark(popup.buf, namespace, index - 1, 0, {
        end_col = #name,
        hl_group = 'DbLensHeader',
      })
      if result.rows[row][index] == protocol.NULL then
        vim.api.nvim_buf_set_extmark(popup.buf, namespace, index - 1, width + 2, {
          end_col = #line,
          hl_group = 'DbLensNull',
        })
      end
    end
  end
  return popup
end

local function show_ddl(state, relation, text)
  return float.open(vim.split(text, '\n', { plain = true }), state.options, {
    title = ('DDL - %s'):format(relation.name),
    footer = 'q close',
    filetype = 'sql',
    min_width = 60,
  })
end

--- The DDL for a relation: asked of the database when it can answer, rebuilt from the catalog
--- when it cannot (postgres has no SHOW CREATE).
---@param state dblens.State
---@param relation dblens.Relation
function M.ddl(state, relation)
  local app = require('dblens.app')
  local session = state.session
  if not session then
    return
  end

  if ddl_mod.available(session.adapter) then
    require('dblens.loader').relation_details(
      session,
      relation,
      app.live(function(err)
        if err then
          app.error(err)
          return
        end
        show_ddl(
          state,
          relation,
          ddl_mod.reconstruct(relation, session.catalog:info_for(relation), session.adapter.dialect)
        )
      end)
    )
    return
  end

  local statement = session.adapter.sql.ddl(relation)
  if not statement then
    app.error(('%s cannot show DDL for this object'):format(session.adapter.label))
    return
  end
  -- `live`: this opens a float from the callback, so it must not fire into a UI the user closed
  -- or reopened while the client was still running.
  session:run(
    statement,
    {},
    app.live(function(result, err)
      if err then
        app.error(err)
        return
      end
      -- sqlite returns one column, mysql's SHOW CREATE returns (name, ddl).
      local row = result.rows[1]
      if not row then
        app.error('no DDL was returned for ' .. relation.name)
        return
      end
      show_ddl(state, relation, protocol.tostring(row[#row]))
    end)
  )
end

return M
