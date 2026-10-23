vim9script

if exists('g:loaded_vrc_plugin')
  finish
endif
g:loaded_vrc_plugin = '4.0.0'

command! -range VrcQuery call g:VrcQuery(<line1>, <line2>)
command! -range VrcHandleResponse call g:VrcHandleResponse()

nnoremap <silent> <Plug>(vrc-query)
  \ <Cmd>call g:VrcQuery()<CR>
xnoremap <silent> <Plug>(vrc-query)
  \ <Cmd>call g:VrcQuery(line("'<"), line("'>"))<CR>
inoremap <silent> <Plug>(vrc-query)
  \ <Esc>:call g:VrcQuery()<CR>

nnoremap <silent> <Plug>(vrc-handle-response)
  \ <Cmd>call g:VrcHandleResponse()<CR>
xnoremap <silent> <Plug>(vrc-handle-response)
  \ <Cmd>call g:VrcHandleResponse(line("'<"), line("'>"))<CR>

def g:VrcQuery(...lines: list<number>): void
  if &filetype !=# 'rest'
    echom 'VrcQuery: current buffer is not a rest buffer'
    return
  endif
  if len(lines) >= 2
    vrc#Query(lines[0], lines[1])
  elseif len(lines) == 1
    vrc#Query(lines[0], lines[0])
  else
    vrc#Query()
  endif
enddef

def g:VrcMap(): void
  if &filetype !=# 'rest'
    echom 'VrcMap: current buffer is not a rest buffer'
    return
  endif
  vrc#Map()
enddef

# :def cannot receive a range.  Keep this tiny legacy definition so the
# documented `:1,5call VrcHandleResponse()` form continues to work.
execute "function! g:VrcHandleResponse() range\n"
  .. "  if &filetype !=# 'rest'\n"
  .. "    echom 'VrcHandleResponse: current buffer is not a rest buffer'\n"
  .. "    return\n"
  .. "  endif\n"
  .. "  call vrc#HandleResponse(a:firstline, a:lastline)\n"
  .. "endfunction"
