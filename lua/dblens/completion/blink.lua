--- blink.cmp source over `dblens.completion`.
---
--- Loads with or without blink.cmp installed: the plugin is only required from `setup`, and items
--- carry plain LSP kind numbers rather than blink's enum.
local completion = require('dblens.completion')

local M = {}

local SOURCE_NAME = 'dblens'
local MODULE = 'dblens.completion.blink'

--- LSP CompletionItemKind numbers: Class = 7, Field = 5, Keyword = 14.
local LSP_KIND = { keyword = 14, table = 7, view = 7, column = 5 }

local Source = {}
Source.__index = Source

--- blink instantiates the source module itself, so `new` is part of its contract.
---@return table source
function M.new()
  return setmetatable({}, Source)
end

function Source.enabled()
  return completion.is_attached(vim.api.nvim_get_current_buf())
end

--- A dot re-opens the menu, which is what turns `u.` into column completion.
function Source.get_trigger_characters()
  return { '.' }
end

--- Answer one completion request.
---
--- The list is marked incomplete in both directions because it depends on where the cursor is:
--- crossing a `.` changes it entirely, so blink must ask again rather than filter its cache.
---@param ctx table  blink context: `bufnr` plus `cursor` as { 1-based row, 0-based byte col }
---@param callback fun(response: table)
---@return fun() cancel
function Source.get_completions(_self, ctx, callback)
  assert(type(callback) == 'function', 'completion.blink: blink must pass a callback')
  assert(
    type(ctx) == 'table' and type(ctx.cursor) == 'table',
    'completion.blink: blink passed no cursor context'
  )
  local row, col = ctx.cursor[1], ctx.cursor[2]
  assert(
    type(row) == 'number' and type(col) == 'number',
    'completion.blink: unexpected cursor shape'
  )
  local items = completion.complete_at(ctx.bufnr or vim.api.nvim_get_current_buf(), row, col)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = {
      label = item.word,
      kind = LSP_KIND[item.kind],
      detail = item.detail,
      labelDetails = { description = item.menu },
    }
  end
  callback({ items = out, is_incomplete_forward = true, is_incomplete_backward = true })
  -- The work above is synchronous, so there is nothing left to cancel.
  return function() end
end

local notified = false

--- Say once, out loud, that blink cannot be wired up automatically. Silence here would look like
--- working completion that never fires.
local function warn_manual_setup()
  if notified then
    return
  end
  notified = true
  vim.notify(
    ('dblens: blink.cmp is installed but exposes no source registration API; add `%s = { module = "%s" }` to your blink sources'):format(
      SOURCE_NAME,
      MODULE
    ),
    vim.log.levels.WARN
  )
end

local registered = false

--- Register the source with blink and enable it for the buffer's filetype. A missing blink.cmp is
--- not a failure: the omnifunc path covers the buffer either way.
---@param bufnr integer
---@return boolean enabled
function M.setup(bufnr)
  assert(type(bufnr) == 'number' and bufnr > 0, 'completion.blink.setup: expected a buffer number')
  assert(vim.api.nvim_buf_is_valid(bufnr), 'completion.blink.setup: buffer is not valid')
  local blink = completion.optional_require('blink.cmp')
  if not blink then
    return false
  end
  if
    type(blink.add_source_provider) ~= 'function' or type(blink.add_filetype_source) ~= 'function'
  then
    warn_manual_setup()
    return false
  end
  if not registered then
    blink.add_source_provider(SOURCE_NAME, { name = SOURCE_NAME, module = MODULE })
    registered = true
  end
  local filetype = vim.bo[bufnr].filetype
  if filetype ~= '' then
    blink.add_filetype_source(filetype, SOURCE_NAME)
  end
  return true
end

return M
