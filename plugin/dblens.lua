-- dblens.nvim command surface. Kept free of top-level requires so startup stays cheap.
if vim.g.loaded_dblens then
  return
end
vim.g.loaded_dblens = true

if vim.fn.has('nvim-0.10') ~= 1 then
  vim.notify('dblens.nvim requires Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

local function command(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

local function complete_connections()
  return require('dblens').connection_names()
end

command('DbLens', function(args)
  require('dblens').open(args.args)
end, { nargs = '?', complete = complete_connections, desc = 'Open dblens' })

command('DbLensClose', function()
  require('dblens').close()
end, { desc = 'Close dblens and restore the previous layout' })

command('DbLensToggle', function()
  require('dblens').toggle()
end, { desc = 'Toggle dblens' })

command('DbLensConnections', function()
  local dblens = require('dblens')
  dblens.ensure_setup()
  if not dblens.is_open() then
    dblens.open()
    return
  end
  require('dblens.ui.picker').connections(require('dblens.app').state())
end, { desc = 'Pick a dblens connection' })

command('DbLensAdd', function()
  require('dblens').add_connection()
end, { desc = 'Add a dblens connection' })

command('DbLensRemove', function(args)
  require('dblens').remove_connection(args.args)
end, { nargs = 1, complete = complete_connections, desc = 'Remove a dblens connection' })

command('DbLensRestore', function()
  require('dblens').restore()
end, { desc = 'Reopen the last dblens session' })

-- Defer so a user's own `setup{}` wins; this only fills in for zero-config users.
vim.schedule(function()
  require('dblens').ensure_setup()
end)
