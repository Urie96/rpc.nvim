" Vim syntax file for RPC request files (.rpc)
" Format:
"   PSM: some.service
"   Method: SomeMethod
"   ENV: production
"   (optional metadata...)
"   (blank line)
"   { "json": body }
"   ### (block separator for multiple requests)

if exists('b:current_syntax')
  finish
endif

syntax include @RpcJson syntax/json.vim
unlet b:current_syntax

syntax match rpcSeparator /^\s*###/ nextgroup=rpcBlockTitle skipwhite
syntax match rpcBlockTitle /.*$/ contained
syntax match rpcComment /^\s*#\%([^#].*\)\?$/ containedin=ALLBUT,rpcBody
syntax match rpcMetaKey /^\s*\zs[A-Za-z_][A-Za-z0-9_]*\ze\s*:/ containedin=ALLBUT,rpcBody
syntax match rpcMetaColon /:/ containedin=ALLBUT,rpcBody
syntax match rpcMetaValue /:\s*\zs.*$/ containedin=ALLBUT,rpcBody
syntax region rpcBody start=/^\s*$/ end=/^\s*###/me=s-1 keepend contains=@RpcJson

highlight default link rpcSeparator Delimiter
highlight default link rpcBlockTitle Title
highlight default link rpcComment Comment
highlight default link rpcMetaKey Identifier
highlight default link rpcMetaColon Delimiter
highlight default link rpcMetaValue String

let b:current_syntax = 'rpc'
