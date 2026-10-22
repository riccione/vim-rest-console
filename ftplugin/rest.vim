vim9script

if exists('b:did_ftplugin')
  finish
endif
b:did_ftplugin = 1

setlocal commentstring=#%s
b:undo_ftplugin = 'setlocal commentstring<'

if vrc#opt#Get('vrc_set_default_mapping', 1)
  vrc#Map()
endif
