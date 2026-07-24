" Vim syntax file for RPC request files (.rpc)
" Format:
"   RPC SayHello                    <- first line (two tokens, Keyword + Function)
"   PSM: some.service              <- metadata (Key: Value)
"   ENV: production
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

" First line — two tokens (e.g., "RPC SayHello").
" :\@! rejects lines where the first token is followed by ':'
" (metadata), completely avoiding any overlap with rpcMetaKey etc.
syntax match rpcFirstLine1 /^\S\+:\@!/ containedin=ALLBUT,rpcBody nextgroup=rpcFirstLineSep
syntax match rpcFirstLineSep /\s\+/ contained nextgroup=rpcFirstLine2
syntax match rpcFirstLine2 /\S\+/ contained

syntax region rpcBody start=/^\s*$/ end=/^\s*###/me=s-1 keepend contains=@RpcJson

highlight default link rpcFirstLine1 Keyword
highlight default link rpcFirstLine2 Function
highlight default link rpcSeparator Delimiter
highlight default link rpcBlockTitle Title
highlight default link rpcComment Comment
highlight default link rpcMetaKey Identifier
highlight default link rpcMetaColon Delimiter
highlight default link rpcMetaValue String

let b:current_syntax = 'rpc'
