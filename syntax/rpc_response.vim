if exists('b:current_syntax')
  finish
endif

" Force full re-sync so rpcRespBody region is detected
" even when scrolling deep into the JSON body
syntax sync fromstart

" Syntax file for RPC response buffers
" Format:
"   Key: Value           <- metadata headers (highlighted as Identifier/String)
"   Another-Key: Value
"   ---                  <- optional separator
"   { "json": body }    <- JSON body (standard JSON highlighting + folding)
"
" Highlight metadata header lines (Key: Value)
syntax match rpcRespKey /^[A-Za-z_][A-Za-z0-9_-]*/ nextgroup=rpcRespColon
syntax match rpcRespColon /:\s*/ contained nextgroup=rpcRespValue
syntax match rpcRespValue /.*$/ contained

" Separator line
syntax match rpcRespSeparator /^---$/

" Include JSON syntax items for highlighting
syntax include @RpcRespJson syntax/json.vim
unlet b:current_syntax

" Body container from first {/[ to EOF (contains JSON items for highlighting)
syntax region rpcRespBody start=/^[{\[]/ end=/\%$/ keepend contains=@RpcRespJson

highlight default link rpcRespKey Identifier
highlight default link rpcRespColon Delimiter
highlight default link rpcRespValue String
highlight default link rpcRespSeparator Delimiter

let b:current_syntax = 'rpc_response'
