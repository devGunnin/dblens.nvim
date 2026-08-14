--- Explicit transaction mode.
---
--- CLI clients are one-shot processes, so a transaction cannot be held open across calls the way
--- a socket session would. dblens therefore *defers*: while transaction mode is on, every change
--- is queued, and COMMIT replays the queue inside a single `BEGIN; ...; COMMIT;` invocation.
--- ROLLBACK is free because nothing was sent.
---
--- Atomicity is the client's flags, not the wrapper: `sqlite3` without `-bail` prints the error,
--- SKIPS the failing statement and runs the trailing COMMIT, committing part of the batch.
---
--- Consequence the UI must own: queued changes are not visible to the server until commit, so
--- the grid marks them as pending rather than pretending they landed.
local M = {}

---@class dblens.PendingChange
---@field sql string
---@field summary string
---@field guard string?  -- count(*) that must return exactly 1, re-checked at commit time
---@field relation dblens.Relation?
---@field key dblens.KeyValue[]?
---@field column string?
---@field value any

---@class dblens.ScriptOwner
---@field index integer  -- 1-based position in the queue
---@field guard boolean  -- the line is the change's guard rather than the change itself

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
---
--- Each guard is emitted INTO the batch, before the change it guards. Running it at queue time
--- only proved the predicate against the database as it was then, in a separate connection,
--- with none of the other queued changes applied — so a later queued change could make an
--- earlier one's predicate match two rows and it would apply to both.
---@param assert_one fun(count_sql: string): string  -- statement that fails unless the count is 1
---@return string? script, string? error, table<integer, dblens.ScriptOwner>? owner_of_line
function Txn:script(assert_one)
  assert(type(assert_one) == 'function', 'txn:script: needs the adapter guard builder')
  if not self.active then
    return nil, 'not in a transaction'
  end
  if #self.pending == 0 then
    return nil, 'nothing to commit'
  end

  local parts, owners, line = {}, {}, 0
  local function emit(text, owner)
    parts[#parts + 1] = text
    local _, breaks = text:gsub('\n', '')
    for _ = 1, breaks + 1 do
      line = line + 1
      owners[line] = owner
    end
  end

  emit('BEGIN;', nil)
  for index, change in ipairs(self.pending) do
    if change.guard then
      emit(assert_one(change.guard) .. ';', { index = index, guard = true })
    end
    emit(change.sql .. ';', { index = index, guard = false })
  end
  emit('COMMIT;', nil)
  return table.concat(parts, '\n'), nil, owners
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
