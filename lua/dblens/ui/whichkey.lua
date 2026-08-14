--- which-key integration: name the dblens prefix, nothing more.
---
--- Every binding already carries a `desc`, which which-key reads by itself, so the only thing
--- missing from its menu is a label for the prefix the global maps share. That prefix is derived
--- from the bindings actually resolved, so a user who remaps them does not get a group pointing
--- at keys they no longer use.
local keymaps = require('dblens.keymaps')

local M = {}

--- The key sequence every one of these bindings starts with, or nil when they share none.
---
--- Byte-wise, then rejected if it stops inside a `<...>` token: `<leader>x` and `<localleader>y`
--- share the bytes `<l`, which is not a key sequence.
---@param lhs_list string[]
---@return string?
function M.common_prefix(lhs_list)
  assert(vim.islist(lhs_list), 'whichkey.common_prefix: expected a list')
  if #lhs_list < 2 then
    return nil
  end
  local prefix = lhs_list[1]
  for index = 2, #lhs_list do
    local other, at = lhs_list[index], 0
    while at < #prefix and at < #other and prefix:byte(at + 1) == other:byte(at + 1) do
      at = at + 1
    end
    prefix = prefix:sub(1, at)
    if prefix == '' then
      return nil
    end
  end
  local _, opens = prefix:gsub('<', '')
  local _, closes = prefix:gsub('>', '')
  if opens ~= closes then
    return nil
  end
  for _, lhs in ipairs(lhs_list) do
    if lhs == prefix then
      return nil
    end
  end
  return prefix
end

--- Hand the prefix to whichever which-key API this version has.
local function label(which_key, prefix)
  if type(which_key.add) == 'function' then
    which_key.add({ { prefix, group = 'dblens' } })
    return true
  end
  if type(which_key.register) == 'function' then
    which_key.register({ [prefix] = { name = '+dblens' } })
    return true
  end
  return false
end

---@param options table  resolved config
---@return boolean  -- whether which-key was there and took the label
local function try_register(options)
  local present, which_key = pcall(require, 'which-key')
  if not present then
    return false
  end
  local lhs_list = {}
  for _, entry in ipairs(keymaps.resolve('global', options.keymaps.global)) do
    vim.list_extend(lhs_list, entry.lhs)
  end
  local prefix = M.common_prefix(lhs_list)
  if not prefix then
    return true
  end
  -- A broken optional integration must not take the user's whole config down with it, but it
  -- must not disappear either.
  local ok, err = pcall(label, which_key, prefix)
  if not ok then
    vim.notify('dblens: which-key registration failed: ' .. tostring(err), vim.log.levels.WARN)
  end
  return true
end

--- Register the group label, retrying once after startup for a lazily loaded which-key.
---@param options table  resolved config
function M.setup(options)
  assert(type(options) == 'table' and options.keymaps, 'whichkey.setup: needs resolved options')
  if try_register(options) then
    return
  end
  vim.api.nvim_create_autocmd('UIEnter', {
    once = true,
    desc = 'dblens: label the keymap prefix once which-key has loaded',
    callback = function()
      try_register(options)
    end,
  })
end

return M
