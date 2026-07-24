-- ftplugin for RPC request files (.rpc)
-- Guard: only apply to buffers with the exact 'rpc' filetype.
-- Neovim's :packadd may source mismatched ftplugin files from opt/ plugins.
if vim.bo.filetype ~= 'rpc' then
  return
end

vim.bo.buftype = ''
vim.bo.commentstring = '# %s'

vim.keymap.set('n', '<CR>', function()
  require('rpc').run_current()
end, { buffer = true, silent = true, desc = 'Run current RPC request' })

vim.api.nvim_buf_create_user_command(0, 'RpcRun', function()
  require('rpc').run_current()
end, { desc = 'Run current RPC request' })
