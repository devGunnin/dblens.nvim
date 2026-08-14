--- The write path, which had no coverage at all: the gate every statement passes, the
--- exactly-one-row guard, cancellation, and transaction atomicity.
---
--- Every case drives a real `dblens.session` over a scripted client double, so the assertions
--- are about what dblens would actually send and what it does with what comes back.
local h = require('helpers')
local protocol = require('dblens.protocol')

local eq, neq = h.eq, h.neq

--- Client stdout for a one-column, one-row result.
local function scalar(name, value)
  return h.wire({ h.record(name), h.record(tostring(value)) })
end

local function ok_result()
  return {}
end

describe('session: the gate', function()
  it('sends a read straight through and reports the rows', function()
    h.with_fake_exec(function()
      return { stdout = scalar('n', 7) }
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod)
      local box = h.capture()
      session:run('SELECT count(*) AS n FROM t', {}, box.sink)
      eq(box[2], nil)
      eq(box[1].columns, { 'n' })
      eq(box[1].rows, { { '7' } })
      eq(#calls, 1)
      eq(calls[1].stdin, 'SELECT count(*) AS n FROM t')
    end)
  end)

  it('refuses an unconfirmed destructive write', function()
    h.with_fake_exec(ok_result, function(session_mod, calls)
      local session = h.fake_session(session_mod, {}, { safety = { confirm_destructive = true } })
      local box = h.capture()
      session:run('DELETE FROM t WHERE id = 1', {}, box.sink)
      eq(type(box[2]), 'string')
      eq(#calls, 0)
    end)
  end)

  it('lets a confirmed destructive write through', function()
    h.with_fake_exec(function()
      return { stdout = scalar('affected', 1) }
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod, {}, { safety = { confirm_destructive = true } })
      local box = h.capture()
      session:run('DELETE FROM t WHERE id = 1', { approval = { confirmed = true } }, box.sink)
      eq(box[2], nil)
      eq(#calls, 1)
    end)
  end)

  it('does not need confirmation when the policy does not ask for one', function()
    h.with_fake_exec(ok_result, function(session_mod, calls)
      local session = h.fake_session(
        session_mod,
        {},
        { safety = { confirm_destructive = false, confirm_write = false } }
      )
      local box = h.capture()
      session:run('DELETE FROM t WHERE id = 1', {}, box.sink)
      eq(box[2], nil)
      eq(#calls, 1)
    end)
  end)
end)

describe('session: execute_write', function()
  local CHANGE = {
    sql = "UPDATE t SET v = 'x' WHERE id = '1'",
    summary = 'set v',
    destructive = true,
    confirmed = true,
    guard = "SELECT count(*) AS n FROM t WHERE id = '1'",
  }

  it('refuses on a read-only connection before running the guard', function()
    h.with_fake_exec(ok_result, function(session_mod, calls)
      local session = h.fake_session(session_mod, { read_only = true })
      local box = h.capture()
      session:execute_write(vim.deepcopy(CHANGE), box.sink)
      eq(box[1], nil)
      eq(type(box[2]), 'string')
      eq(#calls, 0)
    end)
  end)

  it('refuses an unconfirmed destructive change', function()
    h.with_fake_exec(ok_result, function(session_mod, calls)
      local session = h.fake_session(session_mod)
      local request = vim.tbl_extend('force', CHANGE, { confirmed = false })
      local box = h.capture()
      session:execute_write(request, box.sink)
      eq(type(box[2]), 'string')
      eq(#calls, 0)
    end)
  end)

  it('refuses when the guard does not match exactly one row', function()
    for _, count in ipairs({ 0, 2 }) do
      h.with_fake_exec(function()
        return { stdout = scalar('n', count) }
      end, function(session_mod, calls)
        local session = h.fake_session(session_mod)
        local box = h.capture()
        session:execute_write(vim.deepcopy(CHANGE), box.sink)
        eq(box[1], nil, { fail_reason = ('count %d must be refused'):format(count) })
        eq(type(box[2]), 'string')
        eq(#calls, 1, { fail_reason = 'only the guard may run' })
      end)
    end
  end)

  it('applies the change and reports the affected count when the guard passes', function()
    h.with_fake_exec(function(_, index)
      return { stdout = index == 1 and scalar('n', 1) or scalar('affected', 1) }
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod)
      local box = h.capture()
      session:execute_write(vim.deepcopy(CHANGE), box.sink)
      eq(box[2], nil)
      eq(box[1].queued, false)
      eq(box[1].affected, 1)
      eq(#calls, 2)
      -- The affected-row query has to ride the same client invocation to report anything.
      neq(calls[2].stdin:find('changes()', 1, true), nil)
    end)
  end)
end)

describe('session: cancellation', function()
  it('hands back a handle that stops an editor script mid-flight', function()
    h.with_fake_exec(function()
      return { pending = true }
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod)
      local box = h.capture()
      local job = session:run_script({ 'SELECT 1', 'SELECT 2' }, {}, box.sink)
      eq(type(job.cancel), 'function')
      eq(#calls, 1)
      job.cancel()
      eq(calls[1].cancelled, true)
      calls[1].resume({ ok = false, code = 1, reason = 'cancelled' })
      eq(box.called, true)
      eq(#calls, 1, { fail_reason = 'a cancelled script must not start the next statement' })
    end)
  end)

  it('stops a script at the first failure', function()
    h.with_fake_exec(function(_, index)
      if index == 2 then
        return { ok = false, code = 1, stderr = 'boom' }
      end
      return {}
    end, function(session_mod, calls)
      local session = h.fake_session(session_mod)
      local box = h.capture()
      session:run_script({ 'SELECT 1', 'SELECT 2', 'SELECT 3' }, {}, box.sink)
      eq(#calls, 2)
      eq(#box[1], 2)
      eq(type(box[1][2].err), 'string')
    end)
  end)
end)

describe('session: transactions are atomic or they are not applied', function()
  local function queued_session(session_mod)
    local session = h.fake_session(session_mod)
    assert(session.txn:begin())
    session.txn:add({
      sql = "UPDATE t SET v = 'a' WHERE id = '1'",
      summary = 'a',
      guard = "SELECT count(*) AS n FROM t WHERE id = '1'",
    })
    session.txn:add({ sql = "INSERT INTO t VALUES ('2')", summary = 'b' })
    return session
  end

  it('commits one script wrapped in BEGIN/COMMIT with the guards inside it', function()
    h.with_fake_exec(ok_result, function(session_mod, calls)
      local session = queued_session(session_mod)
      local box = h.capture()
      session:commit(box.sink)
      eq(box[1], true)
      eq(#calls, 1, { fail_reason = 'the batch must be one client invocation' })
      local script = calls[1].stdin
      neq(script:find('^BEGIN;'), nil)
      neq(script:find('COMMIT;%s*$'), nil)
      -- The exactly-one-row guard has to be re-checked inside the transaction, not only at
      -- queue time against a state none of the other queued changes had been applied to.
      neq(script:find('count(*)', 1, true), nil)
      eq(session.txn:is_active(), false)
      eq(session.txn:count(), 0)
    end)
  end)

  it('names which queued change failed', function()
    h.with_fake_exec(function()
      return { ok = false, code = 1, stderr = 'Parse error near line 4: no such column: nope' }
    end, function(session_mod)
      local session = queued_session(session_mod)
      local box = h.capture()
      session:commit(box.sink)
      eq(box[1], false)
      neq(box[2]:find('change', 1, true), nil, { fail_reason = 'the report must name the change' })
    end)
  end)

  it('keeps the queue when the client aborted the batch, so a retry cannot double-apply', function()
    h.with_fake_exec(function()
      return { ok = false, code = 1, stderr = 'Parse error near line 4: no such column: nope' }
    end, function(session_mod)
      local session = queued_session(session_mod)
      local box = h.capture()
      session:commit(box.sink)
      eq(box[3], true, { fail_reason = 'a clean abort leaves the queue safe to retry' })
      eq(session.txn:count(), 2)
    end)
  end)

  it('drops the queue when the client was killed and the outcome is unknown', function()
    for _, reason in ipairs({ 'timeout', 'cancelled', 'max_bytes' }) do
      h.with_fake_exec(function()
        return { ok = false, code = -1, reason = reason }
      end, function(session_mod)
        local session = queued_session(session_mod)
        local box = h.capture()
        session:commit(box.sink)
        eq(box[1], false)
        eq(box[3], false, { fail_reason = reason .. ': the queue must not be preserved blindly' })
        eq(session.txn:count(), 0, { fail_reason = reason .. ': queue must be cleared' })
        neq(box[2]:find('verify', 1, true), nil, { fail_reason = 'the user must be told to check' })
      end)
    end
  end)

  --- The byte cap kills the client with output already collected, so the real result carries
  --- `truncated = true`. That flag routed the kill down the SUCCESS path: the UI reported
  --- "committed N change(s)" and cleared the marks while the server had rolled the batch back.
  it('reports failure when the byte cap killed the commit, and does not keep the queue', function()
    h.with_fake_exec(function()
      return {
        ok = false,
        code = -1,
        reason = 'max_bytes',
        truncated = true,
        stdout = string.rep('x', 64),
      }
    end, function(session_mod)
      local session = queued_session(session_mod)
      local box = h.capture()
      session:commit(box.sink)
      eq(box[1], false, { fail_reason = 'a killed commit must not be reported as committed' })
      eq(box[3], false, { fail_reason = 'the queue must not be replayed after an unknown outcome' })
      eq(session.txn:count(), 0)
      neq(box[2]:find('verify', 1, true), nil, { fail_reason = 'the user must be told to check' })
    end)
  end)

  it('reports failure when the byte cap killed a non-transactional write', function()
    h.with_fake_exec(function()
      return { ok = false, code = -1, reason = 'max_bytes', truncated = true, stdout = 'x' }
    end, function(session_mod)
      local session = h.fake_session(session_mod)
      local box = h.capture()
      session:execute_write({ sql = 'DELETE FROM t', summary = 'd', confirmed = true }, box.sink)
      eq(box[1], nil, { fail_reason = 'a killed write must not report an outcome' })
      eq(type(box[2]), 'string', { fail_reason = 'a killed write must report the failure' })
    end)
  end)

  it('still delivers what a truncated READ managed to return', function()
    h.with_fake_exec(function()
      return {
        ok = false,
        code = -1,
        reason = 'max_bytes',
        truncated = true,
        stdout = h.wire({ h.record('a'), h.record('1') }),
      }
    end, function(session_mod)
      local session = h.fake_session(session_mod)
      local box = h.capture()
      session:run('SELECT a FROM t', {}, box.sink)
      eq(box[2], nil, { fail_reason = 'a truncated read is shown, not thrown away' })
      eq(box[1].truncated, true)
      eq(box[1].rows, { { '1' } })
    end)
  end)

  it('refuses to commit on a locked connection', function()
    h.with_fake_exec(ok_result, function(session_mod, calls)
      local session = queued_session(session_mod)
      -- `set_locked` refuses while a queue is pending (below); commit checks the mode itself.
      session.locked = true
      local box = h.capture()
      session:commit(box.sink)
      eq(box[1], false)
      eq(#calls, 0)
    end)
  end)

  it('refuses to lock while changes are queued, rather than stranding them', function()
    h.with_fake_exec(ok_result, function(session_mod)
      local session = queued_session(session_mod)
      local ok, err = session:set_locked(true)
      eq({ ok, session:is_read_only(), session.txn:count() }, { false, false, 2 })
      neq(err, nil)
    end)
  end)
end)

describe('txn: the committed script', function()
  local txn = require('dblens.txn')

  local function assert_one(count_sql)
    return ('SELECT CASE WHEN (%s) = 1 THEN 1 ELSE fail() END'):format(count_sql)
  end

  it('maps a client-reported line back to the change that produced it', function()
    local t = txn.new()
    assert(t:begin())
    t:add({ sql = 'UPDATE a SET x = 1', summary = 'a', guard = 'SELECT count(*) FROM a' })
    t:add({ sql = 'UPDATE b SET x = 2', summary = 'b' })
    local script, err, owners = t:script(assert_one)
    eq(err, nil)
    local lines = vim.split(script, '\n', { plain = true })
    eq(lines[1], 'BEGIN;')
    eq(lines[#lines], 'COMMIT;')
    eq(owners[1], nil, { fail_reason = 'BEGIN belongs to no change' })
    eq(owners[2].index, 1)
    eq(owners[2].guard, true)
    eq(owners[3].index, 1)
    eq(owners[3].guard, false)
    eq(owners[4].index, 2)
  end)

  it('accounts for a multi-line queued statement', function()
    local t = txn.new()
    assert(t:begin())
    t:add({ sql = 'INSERT INTO t (a)\nVALUES (1)', summary = 'x' })
    t:add({ sql = 'UPDATE t SET a = 2', summary = 'y' })
    local script, _, owners = t:script(assert_one)
    local lines = vim.split(script, '\n', { plain = true })
    eq(lines[4], 'UPDATE t SET a = 2;')
    eq(owners[2].index, 1)
    eq(owners[3].index, 1)
    eq(owners[4].index, 2)
  end)

  it('refuses to build a script outside a transaction or with nothing queued', function()
    eq(select(1, txn.new():script(assert_one)), nil)
    local t = txn.new()
    assert(t:begin())
    eq(select(1, t:script(assert_one)), nil)
  end)
end)

describe('exec: which line the client blamed', function()
  local exec = require('dblens.exec')

  it('reads the line number out of each client dialect of error', function()
    eq(exec.error_line('Parse error near line 3: no such column: nope'), 3)
    eq(exec.error_line('Runtime error near line 12: constraint failed'), 12)
    eq(exec.error_line('psql:<stdin>:4: ERROR:  column "x" does not exist'), 4)
    eq(exec.error_line('ERROR 1054 (42S22) at line 7: Unknown column'), 7)
    eq(exec.error_line('some unstructured failure'), nil)
    eq(exec.error_line(''), nil)
  end)
end)

describe('protocol: NULL stays distinguishable', function()
  it('reads the sentinel as NULL and a value as itself', function()
    local decoded = protocol.decode(h.wire({ h.record('a'), h.record(h.NULL_SENTINEL) }))
    eq(decoded.rows[1][1], h.NULL)
  end)
end)
