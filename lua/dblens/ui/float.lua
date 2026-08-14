--- Centered floating windows: the help overlay, row detail, confirmations and pickers.
---
--- One place owns float geometry, borders and the close keys, so every dblens popup behaves the
--- same and none of them can leak a buffer or a window.
local api = vim.api

local M = {}

---@class dblens.Float
---@field win integer
---@field buf integer
---@field close fun()

local function geometry(lines, options, opts)
  local ui_width, ui_height = vim.o.columns, vim.o.lines
  local max_width = math.floor(ui_width * options.ui.float.max_width)
  local max_height = math.floor(ui_height * options.ui.float.max_height)

  local width = opts.min_width or 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(20, math.min(width + 2, max_width))
  local height = math.max(1, math.min(#lines, max_height))

  return {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((ui_height - height) / 2) - 1),
    col = math.max(0, math.floor((ui_width - width) / 2)),
    style = 'minimal',
    border = options.ui.border,
    title = opts.title and (' ' .. opts.title .. ' ') or nil,
    title_pos = opts.title and 'center' or nil,
    footer = opts.footer and (' ' .. opts.footer .. ' ') or nil,
    footer_pos = opts.footer and 'center' or nil,
  }
end

--- Open a float showing `lines`.
---
--- `opts.on_close` runs exactly once, however the float is dismissed.
---@param lines string[]
---@param options table  resolved config
---@param opts { title: string?, footer: string?, min_width: integer?, modifiable: boolean?, filetype: string?, enter: boolean?, on_close: function? }
---@return dblens.Float
function M.open(lines, options, opts)
  assert(vim.islist(lines), 'float.open: lines must be a list')
  opts = opts or {}

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'wipe'
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = opts.modifiable == true

  local win = api.nvim_open_win(buf, opts.enter ~= false, geometry(lines, options, opts))
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = opts.cursorline == true
  vim.wo[win].winhighlight = 'Normal:DbLensNormal,FloatBorder:DbLensBorder,FloatTitle:DbLensTitle'

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
    if opts.on_close then
      opts.on_close()
    end
  end

  for _, lhs in ipairs(opts.close_keys or { 'q', '<Esc>' }) do
    vim.keymap.set(
      'n',
      lhs,
      close,
      { buffer = buf, nowait = true, silent = true, desc = 'dblens: close' }
    )
  end
  -- Dismissing by moving away must clean up too, or the buffer outlives the window.
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  return { win = win, buf = buf, close = close }
end

--- A two-column `key   description` block, aligned, as used by the help overlay.
---@param pairs_list { left: string, right: string }[]
---@param gap integer?
---@return string[]
function M.align(pairs_list, gap)
  local width = 0
  for _, entry in ipairs(pairs_list) do
    width = math.max(width, vim.fn.strdisplaywidth(entry.left))
  end
  local out = {}
  for index, entry in ipairs(pairs_list) do
    local pad = string.rep(' ', width - vim.fn.strdisplaywidth(entry.left) + (gap or 2))
    out[index] = ('  %s%s%s'):format(entry.left, pad, entry.right)
  end
  return out
end

return M
