vim9script

if exists('b:did_indent')
  finish
endif

# Request bodies and responses are commonly JSON.  Reuse Vim's JSON indent
# instead of maintaining a separate copy.
runtime! indent/json.vim

if !exists('b:did_indent')
  b:did_indent = 1
  setlocal nosmartindent
endif

if !exists('b:undo_indent')
  b:undo_indent = 'setlocal indentexpr< indentkeys< smartindent<'
endif
