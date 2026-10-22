vim9script

if exists('g:loaded_vrc_plugin')
  finish
endif
g:loaded_vrc_plugin = 1

command! VrcQuery call g:VrcQuery()
command! -range VrcHandleResponse call g:VrcHandleResponse()

def g:VrcQuery(): void
  if &filetype !=# 'rest'
    echom 'VrcQuery: current buffer is not a rest buffer'
    return
  endif
  vrc#Query()
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
