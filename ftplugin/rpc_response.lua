-- ftplugin for RPC response buffers (.rpc_response)
--
-- Uses the standard tree-sitter http parser for highlighting, same as
-- the .rpc request files.  The response format is:
--   RPC SayHello    <- first line (parsed as url)
--   Key: Value      <- metadata headers
--   (blank line)
--   { "json": body } <- JSON body
--
-- This is structurally identical to a request block (just without the
-- ### separator), so the http parser handles it perfectly.
--
-- Only apply to buffers with the exact 'rpc_response' filetype
if vim.bo.filetype ~= 'rpc_response' then
  return
end

-- Tree-sitter: reuse the standard http parser
local ok_reg = pcall(vim.treesitter.language.register, 'http', 'rpc_response')
if ok_reg then
  pcall(vim.treesitter.start, 0)
end

vim.bo.commentstring = '# %s'
vim.bo.buftype = 'nofile'
vim.bo.bufhidden = 'hide'
vim.bo.swapfile = false
vim.bo.buflisted = false
vim.bo.modified = false
vim.wo.foldmethod = 'indent'
vim.wo.foldlevel = 99
