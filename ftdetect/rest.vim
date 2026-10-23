vim9script

augroup vrc_ftdetect
  autocmd!
  autocmd BufNewFile,BufRead *.rest setfiletype rest
  autocmd BufNewFile,BufRead *.http set filetype=rest
augroup END
