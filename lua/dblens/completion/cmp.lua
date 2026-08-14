--- nvim-cmp source over `dblens.completion`.
---
--- Loads with or without nvim-cmp installed: the plugin is only required from `setup`, and items
--- carry plain LSP kind numbers rather than cmp's enum.
local completion = require('dblens.completion')

local M = {}

local SOURCE_NAME = 'dblens'

--- LSP CompletionItemKind numbers: Class = 7, Field = 5, Keyword = 14.
local LSP_KIND = { keyword = 14, table = 7, view = 7, column = 5 }

local Source = {}
Source.__index = Source

---@return table source  a source object implementing nvim-cmp's source interface
function M.new()
  return setmetatable({}, Source)
end

function Source.get_debug_name()
  return SOURCE_NAME
end

--- A dot re-opens the menu, which is what turns `u.` into column completion.
function Source.get_trigger_characters()
  return { '.' }
end

function Source.is_available()
  return completion.is_attached(vim.api.nvim_get_current_buf())
end

--- Answer one completion request.
---
--- `isIncomplete` is true because the answer depends on where the cursor is: crossing a `.` changes
--- the list entirely, so cmp must ask again rather than filter its cache.
---@param params { context: table }
---@param callback fun(response: table)
function Source.complete(_self, params, callback)
  assert(type(callback) == 'function', 'completion.cmp: cmp must pass a callback')
  local ctx = params and params.context
  assert(
    type(ctx) == 'table' and type(ctx.cursor) == 'table',
    'completion.cmp: cmp passed no cursor context'
  )
  -- cmp reports a 1-based column; the engine takes a 0-based byte column.
  local items = completion.complete_at(ctx.bufnr, ctx.cursor.row, ctx.cursor.col - 1)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = {
      label = item.word,
      kind = LSP_KIND[item.kind],
      detail = item.detail,
      labelDetails = { description = item.menu },
    }
  end
  callback({ items = out, isIncomplete = true })
end

--- Add the source to a buffer's cmp configuration, keeping whatever is already configured.
local function add_to_buffer(cmp, bufnr)
  local sources = vim.deepcopy(cmp.get_config().sources or {})
  for _, source in ipairs(sources) do
    if source.name == SOURCE_NAME then
      return
    end
  end
  table.insert(sources, 1, { name = SOURCE_NAME })
  vim.api.nvim_buf_call(bufnr, function()
    cmp.setup.buffer({ sources = sources })
  end)
end

local registered = false

--- Register the source and enable it for `bufnr`. A missing nvim-cmp is not a failure: the
--- omnifunc path covers the buffer either way.
---@param bufnr integer
---@return boolean enabled
function M.setup(bufnr)
  assert(type(bufnr) == 'number' and bufnr > 0, 'completion.cmp.setup: expected a buffer number')
  assert(vim.api.nvim_buf_is_valid(bufnr), 'completion.cmp.setup: buffer is not valid')
  local cmp = completion.optional_require('cmp')
  if not cmp then
    return false
  end
  assert(type(cmp.register_source) == 'function', 'completion.cmp: nvim-cmp has no register_source')
  if not registered then
    cmp.register_source(SOURCE_NAME, M.new())
    registered = true
  end
  add_to_buffer(cmp, bufnr)
  return true
end

return M
