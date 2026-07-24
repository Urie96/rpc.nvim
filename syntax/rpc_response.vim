if exists('b:current_syntax')
  finish
endif

" Force full re-sync so rpcRespBody region is detected
" even when scrolling deep into the JSON body
syntax sync fromstart

" Syntax file for RPC response buffers
" Format (3 sections separated by a blank line):
"   RPC SayHello                    <- first line (Keyword + Title)
"   Key: Value                      <- metadata headers
"   Another-Key: Value
"                                   <- blank line separator
"   { "json": body }               <- JSON body (standard JSON highlighting)
"
" First line (always the very first buffer line) – two tokens with
" different highlights (e.g., "RPC SayHello").  Defined before rpcRespKey
" so it takes precedence on line 1.
syntax match rpcRespFirstLine1 /\%1l\S\+/ contains=NONE nextgroup=rpcRespFirstLineSep
syntax match rpcRespFirstLineSep /\s\+/ contained contains=NONE nextgroup=rpcRespFirstLine2
syntax match rpcRespFirstLine2 /\S\+/ contained contains=NONE nextgroup=rpcRespFirstLineAfter
" Catch any extra content after the second token (invalid format)
syntax match rpcRespFirstLineAfter /.*/ contained contains=NONE

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

highlight default link rpcRespFirstLine1 Keyword
highlight default link rpcRespFirstLine2 Title
highlight default link rpcRespFirstLineAfter ErrorMsg
highlight default link rpcRespKey Identifier
highlight default link rpcRespColon Delimiter
highlight default link rpcRespValue String
highlight default link rpcRespSeparator Delimiter

let b:current_syntax = 'rpc_response'
