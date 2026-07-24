-- ftplugin for RPC request files (.rpc)
--
-- Uses the standard tree-sitter http parser (tree-sitter-http from
-- nvim-treesitter) for highlighting.  The .rpc format is structurally
-- aligned with .http files:
--   ### separator ~ ### separator
--   RPC Method    ~ METHOD url
--   Key: Value    ~ Key: Value
--   blank + json  ~ blank + json
--   {{var}}       ~ {{var}}
--   @name = val   ~ @name = val
--
-- The parser handles all rpc constructs correctly:
--   request_separator, header, json_body, variable, variable_declaration
-- The only difference: "RPC MethodName" is parsed as URL (method is
-- optional, so it falls through to target_url), giving reasonable
-- highlighting via @string.special.url.
--
-- Guard: only apply to buffers with the exact 'rpc' filetype.
-- Neovim's :packadd may source mismatched ftplugin files from opt/ plugins.
if vim.bo.filetype ~= 'rpc' then
  return
end

vim.bo.buftype = ''
vim.bo.commentstring = '# %s'

-- Tree-sitter: reuse the standard http parser (from nvim-treesitter)
-- No dependency on kulala.nvim.
local ok_reg = pcall(vim.treesitter.language.register, 'http', 'rpc')
if ok_reg then
  pcall(vim.treesitter.start, 0)
end

-- Keymaps
vim.keymap.set('n', '<CR>', function()
  require('rpc').run_current()
end, { buffer = true, silent = true, desc = 'Run current RPC request' })

vim.keymap.set('n', '<leader>i', function()
  require('rpc').inspect_current()
end, { buffer = true, silent = true, desc = 'Inspect current RPC request command' })

vim.api.nvim_buf_create_user_command(0, 'RpcRun', function()
  require('rpc').run_current()
end, { desc = 'Run current RPC request' })

vim.api.nvim_buf_create_user_command(0, 'RpcInspect', function()
  require('rpc').inspect_current()
end, { desc = 'Inspect current RPC request command' })
