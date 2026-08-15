--- Winbar composition and the query spinner.
---
--- The winbar is the whole status surface: which connection, what is shown, how long it took,
--- whether the connection is read-only and whether a transaction is open.
local M = {}

--- `%` is a format character in a winbar, so any text put there must escape it.
local function escape(text)
  return (tostring(text):gsub('%%', '%%%%'))
end

---@class dblens.Segment
---@field text string
---@field hl string?
---@field keep boolean?  -- survives a narrow window; the rest are given up first

--- Build a winbar string from segments.
---@param segments dblens.Segment[]
---@return string
function M.compose(segments)
  local parts = {}
  for _, segment in ipairs(segments) do
    if segment.text and segment.text ~= '' then
      parts[#parts + 1] = ('%%#%s#%s'):format(segment.hl or 'DbLensDim', escape(segment.text))
    end
  end
  -- The tail follows the winbar's own group, not Normal: on a colorscheme where the two differ
  -- the Normal reset painted a visible seam across the rest of the bar.
  parts[#parts + 1] = '%#DbLensWinBar#'
  return table.concat(parts)
end

--- Join segments with a dimmed separator.
---@param segments dblens.Segment[]
---@return dblens.Segment[]
function M.dotted(segments)
  local out = {}
  for _, segment in ipairs(segments) do
    if segment.text and segment.text ~= '' then
      if #out > 0 then
        out[#out + 1] = { text = ' · ', hl = 'DbLensDim' }
      end
      out[#out + 1] = segment
    end
  end
  return out
end

--- Drop and clip segments that do not fit the window, so a long path can never push the winbar
--- past its window and bleed into the pane beside it.
---@param segments dblens.Segment[]
---@param width integer
---@return dblens.Segment[]
function M.fit(segments, width)
  local out, used = {}, 0
  for _, segment in ipairs(segments) do
    local text_width = vim.fn.strdisplaywidth(segment.text)
    if used + text_width <= width then
      out[#out + 1] = segment
      used = used + text_width
    else
      local room = width - used - 1
      if room > 1 then
        out[#out + 1] =
          { text = vim.fn.strcharpart(segment.text, 0, room) .. '…', hl = segment.hl }
      end
      break
    end
  end
  return out
end

--- Choose which segments a `width`-wide winbar can afford, keeping the essential ones.
---
--- A narrow window has to give something up, and what it used to give up was whatever came last
--- — which is the LOCKED/EDIT indicator. So the optional segments go first, from the right, and
--- only when the essential ones alone still do not fit is anything clipped.
---@param segments dblens.Segment[]
---@param width integer
---@return dblens.Segment[]  -- separators included
function M.lay_out(segments, width)
  assert(vim.islist(segments), 'status.lay_out: expected a list of segments')
  assert(type(width) == 'number', 'status.lay_out: needs the window width')
  local kept = {}
  for _, segment in ipairs(segments) do
    if segment.text and segment.text ~= '' then
      kept[#kept + 1] = segment
    end
  end

  local function total(list)
    local used = 0
    for _, segment in ipairs(list) do
      used = used + vim.fn.strdisplaywidth(segment.text)
    end
    -- Three cells per ` · ` separator.
    return used + math.max(0, #list - 1) * 3
  end

  for index = #kept, 1, -1 do
    if total(kept) <= width then
      break
    end
    if not kept[index].keep then
      table.remove(kept, index)
    end
  end
  return M.fit(M.dotted(kept), width)
end

--- Draw the winbar, or clear it when `ui.winbar` is off.
---
--- The option has to be honoured HERE: clearing it once at window setup was undone by the next
--- render, so switching it off did nothing.
---@param win integer
---@param segments dblens.Segment[]
---@param options table  resolved config
function M.set(win, segments, options)
  assert(type(options) == 'table' and options.ui, 'status.set: needs resolved options')
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not options.ui.winbar then
    vim.wo[win].winbar = ''
    return
  end
  local width = vim.api.nvim_win_get_width(win)
  vim.wo[win].winbar = M.compose(M.lay_out(segments, width))
end

---@class dblens.Spinner
local Spinner = {}
Spinner.__index = Spinner

--- A spinner that only exists while something is running.
---@param options table
---@param on_frame fun()
---@return dblens.Spinner
function M.spinner(options, on_frame)
  assert(type(on_frame) == 'function', 'status.spinner: on_frame must be a function')
  return setmetatable({
    frames = options.ui.spinner.frames,
    interval = options.ui.spinner.interval,
    on_frame = on_frame,
    index = 1,
    timer = nil,
    started_at = nil,
  }, Spinner)
end

function Spinner:is_running()
  return self.timer ~= nil
end

function Spinner:start()
  if self.timer then
    return
  end
  self.index = 1
  self.started_at = vim.uv.hrtime()
  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    self.interval,
    vim.schedule_wrap(function()
      self.index = self.index % #self.frames + 1
      self.on_frame()
    end)
  )
end

function Spinner:stop()
  if not self.timer then
    return
  end
  self.timer:stop()
  self.timer:close()
  self.timer = nil
  self.started_at = nil
  self.on_frame()
end

--- Current frame plus how long the work has been running.
---@return string
function Spinner:label()
  if not self.timer then
    return ''
  end
  local seconds = (vim.uv.hrtime() - self.started_at) / 1e9
  return ('%s %.1fs'):format(self.frames[self.index], seconds)
end

--- Human duration for a finished query.
---@param ms number
---@return string
function M.duration(ms)
  if ms < 1000 then
    return ('%.0fms'):format(ms)
  end
  return ('%.2fs'):format(ms / 1000)
end

return M
