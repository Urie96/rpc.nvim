-- Only apply to buffers with the exact 'rpc_response' filetype
if vim.bo.filetype ~= 'rpc_response' then
  return
end

vim.bo.commentstring = '# %s'
vim.bo.buftype = 'nofile'
vim.bo.bufhidden = 'hide'
vim.bo.swapfile = false
vim.bo.buflisted = false
vim.bo.modified = false
vim.wo.foldmethod = 'indent'
vim.wo.foldlevel = 99
