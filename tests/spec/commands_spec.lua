--- The `:DbLens…` command surface. Every global binding has a command that runs the same
--- handler, and every command is documented in both the README and the vimdoc.
local h = require('helpers')
local keymaps = require('dblens.keymaps')

local eq, expect_error = h.eq, h.expect_error

--- Load `plugin/dblens.lua` into this session and report the commands it defined.
---@return table<string, table>
local function defined_commands()
  vim.g.loaded_dblens = nil
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:sub(1, 6) == 'DbLens' then
      pcall(vim.api.nvim_del_user_command, name)
    end
  end
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
  vim.cmd('source ' .. vim.fn.fnameescape(root .. '/plugin/dblens.lua'))
  local out = {}
  for name, command in pairs(vim.api.nvim_get_commands({})) do
    if name:sub(1, 6) == 'DbLens' then
      out[name] = command
    end
  end
  return out
end

--- Actions the commands are expected to cover, and the command that covers each.
local ACTION_COMMANDS = {
  toggle = 'DbLensToggle',
  connections = 'DbLensConnections',
  query = 'DbLensQuery',
  tables = 'DbLensTables',
  history = 'DbLensHistory',
  snippets = 'DbLensSnippets',
  write_toggle = 'DbLensWrite',
  lock = 'DbLensLock',
  txn_begin = 'DbLensBegin',
  txn_commit = 'DbLensCommit',
  txn_rollback = 'DbLensRollback',
  txn_pending = 'DbLensPending',
}

describe('commands', function()
  it('defines one for every global binding', function()
    local commands = defined_commands()
    for _, spec in ipairs(keymaps.specs.global) do
      local name = ACTION_COMMANDS[spec.action]
      eq(name ~= nil, true, {
        fail_reason = ('global action `%s` has no command'):format(spec.action),
      })
      eq(commands[name] ~= nil, true, { fail_reason = ('`:%s` is not defined'):format(name) })
    end
  end)

  it('describes every command it defines', function()
    -- `nvim_get_commands` reports a callback command's desc via `definition` on 0.10/stable and
    -- via a separate `desc` field on nightly, so a real description shows up in either.
    for name, command in pairs(defined_commands()) do
      local description = command.desc or command.definition or ''
      eq(description ~= '', true, {
        fail_reason = ':' .. name .. ' has no description',
      })
    end
  end)

  it('completes connection names where a connection is the argument', function()
    local commands = defined_commands()
    eq(commands.DbLens.nargs, '?')
    eq(commands.DbLensRemove.nargs, '1')
    -- `nvim_get_commands` reports a Lua completion as the STRING `<Lua function>` on 0.10 and as
    -- the function itself from 0.11 on, so the assertion is that one is wired up at all.
    for _, name in ipairs({ 'DbLens', 'DbLensRemove' }) do
      local complete = commands[name].complete
      eq(complete ~= nil and complete ~= '', true, {
        fail_reason = (':%s completes nothing'):format(name),
      })
    end
  end)

  it('is listed in the README and the vimdoc, every one of them', function()
    local readme = h.repo_file('README.md')
    local doc = h.repo_file('doc/dblens.txt')
    for name in pairs(defined_commands()) do
      -- `:DbLensRemove {name}` carries its argument inside the same span.
      eq(readme:find('`:' .. name .. '[^%w]') ~= nil, true, {
        fail_reason = ':' .. name .. ' is missing from the README',
      })
      eq(doc:find('*:' .. name .. '*', 1, true) ~= nil, true, {
        fail_reason = ':' .. name .. ' has no vimdoc tag',
      })
    end
  end)
end)

describe('dblens.action', function()
  it('runs the same handler the binding runs', function()
    -- `write_toggle` with no session reports it rather than doing anything, which is enough to
    -- prove the command reached the handler instead of a stub.
    local notified = {}
    local real = vim.notify
    vim.notify = function(message)
      notified[#notified + 1] = message
    end
    local ok, err = pcall(require('dblens').action, 'write_toggle')
    vim.notify = real
    eq(ok, true, { fail_reason = tostring(err) })
    eq(#notified, 1)
    eq(notified[1]:find('not connected', 1, true) ~= nil, true)
  end)

  it('refuses an action name that does not exist', function()
    expect_error(function()
      require('dblens').action('nosuchaction')
    end, 'nosuchaction')
  end)
end)
