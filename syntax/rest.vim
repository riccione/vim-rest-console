vim9script

if exists('b:current_syntax')
  finish
endif

syntax case ignore

syntax match restDelimiter /^\s*--\s*$/
syntax match restHost /^\s*https\?:\/\/\S\+$/
syntax match restPipe /^\s*|.*$/

syntax match restVerb /^\s*\%(GET\|POST\|PUT\|DELETE\|HEAD\|PATCH\|OPTIONS\|TRACE\)\s\+/
  \ nextgroup=restPath
syntax match restPath /\S\+/ contained

syntax match restCurlOption /^\s*--\?\w\+/
syntax match restHeader
  \ /^\s*\%(https\?:\/\/\)\@![A-Za-z][A-Za-z0-9-]*\s*:/
  \ nextgroup=restHeaderValue
syntax match restHeaderValue /.*/ contained
syntax match restVariable /^\s*[A-Za-z_][A-Za-z0-9_-]*\s*=/
  \ nextgroup=restValue
syntax match restValue /.*/ contained

# Bodies that start with JSON are highlighted with the runtime JSON syntax.
try
  syntax include @restJson syntax/json.vim
  syntax region restJsonBody start=/^\s*[\[{]/
    \ end=/^\s*[\]}]\s*$/
    \ contains=@restJson
catch
endtry

# Comments are defined last so they take precedence over line-level groups.
syntax region restComment start=/^\s*\%(#\|\/\/\)/
  \ end=/$/
  \ contains=restHandler,restTodo
syntax match restHandler /#\%(>\|%\).*$/ contained
syntax match restTodo /\<\%(TODO\|FIXME\|XXX\|NOTE\)\>/ contained

hi def link restDelimiter PreProc
hi def link restHost Label
hi def link restPipe Special
hi def link restVerb Macro
hi def link restPath String
hi def link restCurlOption Special
hi def link restHeader Identifier
hi def link restHeaderValue String
hi def link restVariable Identifier
hi def link restValue String
hi def link restComment Comment
hi def link restHandler Special
hi def link restTodo Todo

b:current_syntax = 'rest'
