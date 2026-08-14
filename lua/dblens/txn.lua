--- Explicit transaction mode.
---
--- CLI clients are one-shot processes, so a transaction cannot be held open across calls the way
--- a socket session would. dblens therefore *defers*: while transaction mode is on, every change
--- is queued, and COMMIT replays the queue inside a single `BEGIN; ...; COMMIT;` invocation. The
--- batch is genuinely atomic, and ROLLBACK is free because nothing was sent.
---
--- Consequence the UI must own: queued changes are not visible to the server until commit, so
--- the grid marks them as pending rather than pretending they landed.
local M = {}

---@class dblens.PendingChange
---@field sql string
---@field summary string
---@field relation dblens.Relation?
---@field key dblens.KeyValue[]?
---@field column string?
---@field value any

local Txn = {}
Txn.__index = Txn

---@return dblens.Txn
function M.new()
  return setmetatable({ active = false, pending = {} }, Txn)
end

function Txn:is_active()
  return self.active
end

function Txn:count()
  return #self.pending
end

--- Turn transaction mode on. Refuses when already on, so a stray keypress cannot silently
--- discard a queue by restarting it.
---@return boolean ok, string? error
function Txn:begin()
  if self.active then
    return false, 'already in a transaction'
  end
  assert(#self.pending == 0, 'txn: queue must be empty when starting a transaction')
  self.active = true
  return true, nil
end

---@param change dblens.PendingChange
function Txn:add(change)
  assert(self.active, 'txn:add: not in a transaction')
  assert(type(change.sql) == 'string' and change.sql ~= '', 'txn:add: needs SQL')
  self.pending[#self.pending + 1] = change
end

--- The single script COMMIT sends. Statements keep their queued order.
---@return string? script, string? error
function Txn:script()
  if not self.active then
    return nil, 'not in a transaction'
  end
  if #self.pending == 0 then
    return nil, 'nothing to commit'
  end
  local parts = { 'BEGIN;' }
  for _, change in ipairs(self.pending) do
    parts[#parts + 1] = change.sql .. ';'
  end
  parts[#parts + 1] = 'COMMIT;'
  return table.concat(parts, '\n'), nil
end

--- Clear the queue and leave transaction mode. Used by both a successful commit and a rollback.
function Txn:reset()
  self.active = false
  self.pending = {}
end

--- Queued changes touching one relation, for the pending-changes view.
---@return dblens.PendingChange[]
function Txn:for_relation(relation)
  local out = {}
  for _, change in ipairs(self.pending) do
    local at = change.relation
    if at and at.name == relation.name and (at.schema or '') == (relation.schema or '') then
      out[#out + 1] = change
    end
  end
  return out
end

--- Short status for the winbar/statusline, or nil when transaction mode is off.
---@return string?
function Txn:label()
  if not self.active then
    return nil
  end
  return ('TXN %d pending'):format(#self.pending)
end

M.Txn = Txn
return M
