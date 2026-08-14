-- dblens.nvim command surface. Kept free of top-level requires so startup stays cheap.
if vim.g.loaded_dblens then
  return
end
vim.g.loaded_dblens = true

if vim.fn.has('nvim-0.10') ~= 1 then
  vim.notify('dblens.nvim requires Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

local function complete_connections()
  return require('dblens').connection_names()
end

--- Run the same handler the matching keymap runs, so a command and its binding cannot diverge.
local function action(name)
  return function()
    require('dblens').action(name)
  end
end

--- name, handler, options. Every global binding has a command here, and every command is listed
--- in the README and the vimdoc — `tests/spec/commands_spec.lua` fails when one drifts.
local COMMANDS = {
  {
    'DbLens',
    function(args)
      require('dblens').open(args.args)
    end,
    { nargs = '?', complete = complete_connections, desc = 'Open dblens' },
  },
  {
    'DbLensClose',
    function()
      require('dblens').close()
    end,
    { desc = 'Close dblens and restore the previous layout' },
  },
  { 'DbLensToggle', action('toggle'), { desc = 'Toggle dblens' } },
  { 'DbLensConnections', action('connections'), { desc = 'Pick a dblens connection' } },
  { 'DbLensQuery', action('query'), { desc = 'Focus the dblens SQL editor' } },
  { 'DbLensTables', action('tables'), { desc = 'Find a table' } },
  { 'DbLensHistory', action('history'), { desc = 'Browse dblens query history' } },
  { 'DbLensSnippets', action('snippets'), { desc = 'Browse saved dblens snippets' } },
  {
    'DbLensAdd',
    function()
      require('dblens').add_connection()
    end,
    { desc = 'Add a dblens connection' },
  },
  {
    'DbLensRemove',
    function(args)
      require('dblens').remove_connection(args.args)
    end,
    { nargs = 1, complete = complete_connections, desc = 'Remove a dblens connection' },
  },
  {
    'DbLensWrite',
    function()
      require('dblens').write_mode()
    end,
    { desc = 'Open the active dblens connection for editing' },
  },
  {
    'DbLensLock',
    function()
      require('dblens').lock()
    end,
    { desc = 'Lock the active dblens connection read-only' },
  },
  { 'DbLensBegin', action('txn_begin'), { desc = 'Begin a dblens transaction' } },
  { 'DbLensCommit', action('txn_commit'), { desc = 'Commit the dblens transaction' } },
  { 'DbLensRollback', action('txn_rollback'), { desc = 'Roll back the dblens transaction' } },
  { 'DbLensPending', action('txn_pending'), { desc = 'Show pending dblens changes' } },
  {
    'DbLensRestore',
    function()
      require('dblens').restore()
    end,
    { desc = 'Reopen the last dblens session' },
  },
  {
    'DbLensHelp',
    function()
      require('dblens').help()
    end,
    { desc = 'Show every dblens binding for the current pane' },
  },
}

for _, entry in ipairs(COMMANDS) do
  vim.api.nvim_create_user_command(entry[1], entry[2], entry[3])
end

-- Defer so a user's own `setup{}` wins; this only fills in for zero-config users.
vim.schedule(function()
  require('dblens').ensure_setup()
end)
