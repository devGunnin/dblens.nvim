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
  parts[#parts + 1] = '%#Normal#'
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

---@param win integer
---@param segments dblens.Segment[]
function M.set(win, segments)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].winbar = M.compose(M.dotted(segments))
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
