--- The SQL scratch buffer: runs the statement at the cursor, a selection, or the whole buffer.
local keymaps = require('dblens.keymaps')
local layout_mod = require('dblens.ui.layout')
local sqlmod = require('dblens.sql')
local status = require('dblens.ui.status')

local api = vim.api

local M = {}

local WELCOME = {
  '-- dblens scratch buffer',
  '-- <CR> runs the statement at the cursor, or the selection in visual mode',
  '-- ? shows every binding',
  '',
  '',
}

--- Byte offset of the cursor within the buffer's text, 1-based.
local function cursor_offset(buf, win)
  local cursor = api.nvim_win_get_cursor(win)
  local lines = api.nvim_buf_get_lines(buf, 0, cursor[1], false)
  local offset = 0
  for index = 1, #lines - 1 do
    offset = offset + #lines[index] + 1
  end
  return offset + cursor[2] + 1
end

--- The statement the cursor sits in, or the last one when the cursor is past the end.
---@return string?
function M.statement_at_cursor(state)
  local buf, win = state.layout.bufs.editor, state.layout.wins.editor
  if not api.nvim_win_is_valid(win) then
    return nil
  end
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  local dialect = state.session and state.session.adapter.dialect or nil
  local statements = sqlmod.split(text, dialect)
  if #statements == 0 then
    return nil
  end
  local offset = cursor_offset(buf, win)
  for _, statement in ipairs(statements) do
    if offset >= statement.offset and offset <= statement.offset + #statement.sql then
      return statement.sql
    end
  end
  return statements[#statements].sql
end

--- Text of the last visual selection, which is what `<CR>` in visual mode acts on.
---@return string
local function selection_text(buf)
  local from = api.nvim_buf_get_mark(buf, '<')
  local to = api.nvim_buf_get_mark(buf, '>')
  if from[1] == 0 or to[1] == 0 then
    return ''
  end
  local lines = api.nvim_buf_get_lines(buf, from[1] - 1, to[1], false)
  if #lines == 0 then
    return ''
  end
  -- `>` may sit past the end of the line for linewise selections.
  lines[#lines] = lines[#lines]:sub(1, math.min(to[2] + 1, #lines[#lines]))
  lines[1] = lines[1]:sub(from[2] + 1)
  return table.concat(lines, '\n')
end

local function buffer_text(buf)
  return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

---@param state dblens.State
function M.render(state)
  local win = state.layout.wins.editor
  if not api.nvim_win_is_valid(win) then
    return
  end
  local session = state.session
  local segments = {
    { text = ' SQL', hl = 'DbLensTitle' },
    { text = session and session.spec.name or 'not connected', hl = 'DbLensAccent' },
  }
  if session and session.txn:is_active() then
    segments[#segments + 1] = { text = session.txn:label(), hl = 'DbLensTxn' }
  end
  if state.busy then
    segments[#segments + 1] = { text = state.busy, hl = 'DbLensSpinner' }
  end
  status.set(win, segments)
end

local function handlers(state, app)
  local buf = state.layout.bufs.editor

  local function run_current(opts)
    local statement = M.statement_at_cursor(state)
    if not statement then
      app.notify('nothing to run')
      return
    end
    app.run_sql(statement, opts)
  end

  return {
    run = function()
      run_current({})
    end,
    run_selection = function()
      -- leave visual mode first so the `<`/`>` marks are set
      vim.cmd('normal! \27')
      app.run_sql(selection_text(buf), {})
    end,
    run_all = function()
      app.run_sql(buffer_text(buf), {})
    end,
    explain = function()
      run_current({ explain = true, label = 'explain' })
    end,
    explain_analyze = function()
      if state.session and not state.session.adapter.caps.explain_analyze then
        app.error(('%s has no EXPLAIN ANALYZE'):format(state.session.adapter.label))
        return
      end
      run_current({ explain = true, analyze = true, label = 'explain analyze' })
    end,
    cancel = function()
      app.cancel()
    end,
    save_snippet = function()
      require('dblens.ui.picker').save_snippet(
        state,
        M.statement_at_cursor(state) or buffer_text(buf)
      )
    end,
    history = function()
      require('dblens.ui.picker').history(state)
    end,
    help = function()
      require('dblens.ui.help').show(state, 'editor')
    end,
    close = function()
      app.close()
    end,
  }
end

---@param state dblens.State
function M.attach(state)
  local app = require('dblens.app')
  local buf = state.layout.bufs.editor
  layout_mod.set_lines(buf, WELCOME)
  vim.bo[buf].modifiable = true
  keymaps.bind('editor', buf, handlers(state, app), state.options.keymaps.editor)
  if state.options.completion.enabled then
    require('dblens.completion').attach(buf, function()
      return state.session
    end)
  end
  local win = state.layout.wins.editor
  if api.nvim_win_is_valid(win) then
    api.nvim_win_set_cursor(win, { #WELCOME, 0 })
  end
end

return M
