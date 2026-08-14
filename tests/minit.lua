--- Headless test bootstrap.
---
--- `make test` runs it; see the Makefile for the exact one-liner.
--- The runtime is built from exactly two directories -- this worktree and a pinned mini.nvim
--- checkout under `.tests/` -- so a run never depends on the developer's own plugins.

local MINI_URL = 'https://github.com/echasnovski/mini.nvim'
local MINI_PIN = 'v0.18.0'

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local site = root .. '/.tests/site'
local mini = site .. '/pack/deps/start/mini.nvim'

--- Run git, turning a failed command into a fatal message instead of a silent miss.
local function git(args, what)
  assert(type(args) == 'table' and #args > 1, 'minit: git needs arguments')
  assert(type(what) == 'string' and what ~= '', 'minit: git step needs a description')
  local out = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    error(('minit: %s failed (exit %d): %s'):format(what, vim.v.shell_error, out), 0)
  end
end

--- Fetch mini.nvim once, at a fixed tag. Present checkout means an offline, reproducible run.
local function ensure_mini()
  if vim.fn.isdirectory(mini) == 1 then
    return
  end
  vim.fn.mkdir(vim.fn.fnamemodify(mini, ':h'), 'p')
  git({ 'git', 'clone', '--filter=blob:none', MINI_URL, mini }, 'cloning mini.nvim')
  git({ 'git', '-C', mini, 'checkout', '--quiet', MINI_PIN }, 'checking out ' .. MINI_PIN)
  assert(vim.fn.filereadable(mini .. '/lua/mini/test.lua') == 1, 'minit: clone has no mini.test')
end

--- Every spec, in a stable order, addressed absolutely so the run does not depend on cwd.
local function find_files()
  local files = vim.fn.globpath(root .. '/tests', '**/*_spec.lua', true, true)
  assert(#files > 0, 'minit: no *_spec.lua files under tests/')
  table.sort(files)
  return files
end

ensure_mini()

vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(mini)
-- Only this checkout's packages, and no swap or shada left behind. `vim.cmd` because the
-- repo's luacheck config treats `vim` as read-only, so `vim.opt.x = y` is a lint warning.
vim.cmd('set packpath=' .. vim.fn.fnameescape(site) .. ' noswapfile shadafile=NONE')

-- Lets a spec say `require('helpers')` regardless of the directory the suite was started from.
package.path = table.concat({ root .. '/tests/?.lua', package.path }, ';')

require('mini.test').setup({ collect = { find_files = find_files } })
