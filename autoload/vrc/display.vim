vim9script

# Response rendering, formatting, and syntax highlighting.

import autoload 'vrc/opt.vim' as opt
import autoload 'vrc/exec.vim' as exec

def JsonFormatter(): string
  if executable('python3')
    return 'python3 -m json.tool'
  elseif executable('python')
    return 'python -m json.tool'
  elseif executable('jq')
    return 'jq .'
  endif
  return ''
enddef

def XmlFormatter(): string
  return executable('xmllint') ? 'xmllint --format -' : ''
enddef

def DefaultPatterns(): dict<string>
  return {
    'json': JsonFormatter(),
    'xml': XmlFormatter(),
  }
enddef

def GetPatterns(): dict<string>
  var patterns = DefaultPatterns()
  for scope in [g:, b:]
    if has_key(scope, 'vrc_auto_format_response_patterns')
      var userPatterns: any = scope.vrc_auto_format_response_patterns
      if type(userPatterns) == v:t_dict
        extend(patterns, userPatterns)
      endif
    endif
  endfor
  return patterns
enddef

def DecodeSurrogatePair(high: number, low: number): string
  var codepoint = 0x10000 + ((high - 0xD800) * 0x400) + (low - 0xDC00)
  return nr2char(codepoint, true)
enddef

def DecodeUnicodeEscapes(text: string): string
  var result = ''
  var i = 0
  while i < len(text)
    if text[i] == '\' && i + 5 < len(text) && text[i + 1] == 'u'
      var code = str2nr(strpart(text, i + 2, 4), 16)
      if code >= 0xD800 && code <= 0xDBFF
        && i + 11 < len(text)
        && text[i + 6] == '\'
        && text[i + 7] == 'u'
        var low = str2nr(strpart(text, i + 8, 4), 16)
        if low >= 0xDC00 && low <= 0xDFFF
          result ..= DecodeSurrogatePair(code, low)
          i += 12
          continue
        endif
      endif
      result ..= nr2char(code, true)
      i += 6
    else
      result ..= text[i]
      i += 1
    endif
  endwhile
  return result
enddef

def SplitContentType(value: string): string
  return substitute(value, '\v\s*;.*$', '', '')
enddef

def FileTypeFor(contentType: string): string
  var value = SplitContentType(trim(contentType))
  var fileType = substitute(value, '\v^.*/(.*\+)?(.*)$', '\2', 'g')
  if fileType !~# '^[A-Za-z0-9_+-]\+$'
    return ''
  endif
  return fileType
enddef

# Split a response chunk into header text, body text, and body start line.
def ChunkParts(chunk: dict<any>): dict<any>
  var text = get(chunk, 'text', '')
  var hasHeader = get(chunk, 'hasResponseHeader', false)
  var headerText = ''
  var bodyText = text
  var bodyStart = 1
  var fileType = FileTypeFor('' .. opt.Get(
    'vrc_response_default_content_type',
    ''
  ))

  if hasHeader
    var lines = split(text, '\n', true)
    var blankLine = -1
    for index in range(0, len(lines) - 1)
      if lines[index] =~ '^\s*$'
        blankLine = index
        break
      endif
    endfor

    if blankLine >= 0
      headerText = join(lines[0 : blankLine], "\n") .. "\n"
      bodyText = join(lines[blankLine + 1 :], "\n")
      bodyStart = blankLine + 2

      if blankLine > 0
        for index in range(0, blankLine - 1)
          var match = matchlist(
            lines[index],
            '\c^Content-Type:\s*\([^;[:blank:]]*\)'
          )
          if !empty(match)
            fileType = FileTypeFor(match[1])
            break
          endif
        endfor
      endif
    else
      headerText = text
      bodyText = ''
      bodyStart = len(lines) + 1
    endif
  endif

  return {
    'headerText': headerText,
    'bodyText': bodyText,
    'bodyStart': bodyStart,
    'fileType': fileType,
  }
enddef

# Return the filetype derived from a response chunk.
export def DetectContentType(chunk: dict<any>): string
  return ChunkParts(chunk).fileType
enddef

# Format one response chunk and return its complete display text.
export def FormatChunk(chunk: dict<any>): string
  var parts = ChunkParts(chunk)
  var body = parts.bodyText

  if opt.Get('vrc_auto_format_response_enabled', 1)
    var formatCmd = get(GetPatterns(), parts.fileType, '')
    if !empty(formatCmd)
      var result = exec.Shell(formatCmd, body)
      if result.code == 0
        body = substitute(result.out, '\n\+$', '', '')
      elseif opt.Get('vrc_debug', 0)
        echom 'VRC: auto-format error: ' .. result.code
        echom result.err
      endif
    endif
  endif

  if opt.Get('vrc_auto_format_uhex', 0)
    body = DecodeUnicodeEscapes(body)
  endif

  return parts.headerText .. body
enddef

def ApplySyntax(meta: list<dict<any>>): void
  syntax clear
  unlet! b:current_syntax

  var clusters: dict<string> = {}
  var index = 0
  var applied = false
  for item in meta
    if empty(item.fileType)
      continue
    endif

    var cluster = get(clusters, item.fileType, '')
    if empty(cluster)
      cluster = 'vrc_' .. item.fileType
      clusters[item.fileType] = cluster
      unlet! b:current_syntax
      try
        execute 'syntax include @' .. cluster
          .. ' syntax/' .. item.fileType .. '.vim'
      catch
      endtry
    endif

    try
      execute 'syntax region vrcBody' .. index
        .. ' start=/\%' .. item.start .. 'l/'
        .. ' end=/\%' .. item.end .. 'l.*/'
        .. ' contains=@' .. cluster
        .. ' keepend'
      applied = true
    catch
    endtry
    index += 1
  endfor

  if applied
    syntax sync fromstart
  endif
  b:current_syntax = 'vrc'
enddef

# Display response chunks in the output buffer.
export def Show(outputInfo: dict<any>, config: dict<any>): void
  var chunks: list<dict<any>> = get(outputInfo, 'chunks', [])
  var commands: list<string> = get(outputInfo, 'commands', [])
  var bufName = '' .. opt.Get(
    'vrc_output_buffer_name',
    '__REST_response__'
  )

  var bodyLines: list<string> = []
  var meta: list<dict<any>> = []
  var lineCursor = 1
  var chunkIndex = 0

  for chunk in chunks
    var parts = ChunkParts(chunk)
    var formatted = FormatChunk(chunk)
    var chunkLines = split(formatted, '\n', true)
    if !empty(chunkLines) && chunkLines[-1] == ''
      remove(chunkLines, -1)
    endif
    var errorText = get(chunk, 'error', '')
    if !empty(errorText)
      if !empty(chunkLines)
        add(chunkLines, '')
      endif
      var errorLines = split(errorText, '\n', true)
      if !empty(errorLines) && errorLines[-1] == ''
        remove(errorLines, -1)
      endif
      extend(chunkLines, errorLines)
    endif
    if empty(chunkLines)
      chunkLines = ['']
    endif

    var chunkStart = lineCursor
    extend(bodyLines, chunkLines)
    var chunkEnd = lineCursor + len(chunkLines) - 1
    var bodyStart = chunkStart + parts.bodyStart - 1
    if bodyStart <= chunkEnd
      add(meta, {
        'fileType': parts.fileType,
        'start': bodyStart,
        'end': chunkEnd,
      })
    endif

    lineCursor = chunkEnd + 2
    if chunkIndex + 1 < len(chunks)
      add(bodyLines, '')
    endif
    chunkIndex += 1
  endfor

  var lines: list<string> = []
  var prefixCount = 0
  if opt.Get('vrc_show_command_in_result_buffer', 0) && !empty(commands)
    for command in commands
      add(lines, 'REQUEST: ' .. command .. "\t")
    endfor
    add(lines, '')
    prefixCount = len(commands) + 1
  endif
  extend(lines, bodyLines)
  if prefixCount > 0
    for item in meta
      item.start += prefixCount
      item.end += prefixCount
    endfor
  endif
  if empty(lines)
    lines = ['']
  endif

  # Find or create the output buffer.
  var buf = bufnr(bufName)
  if buf == -1
    buf = bufadd(bufName)
    bufload(buf)
  endif

  var origWin = win_getid()
  var win = bufwinid(buf)
  if win == -1
    var cmdSplit = 'vsplit'
    if opt.Get('vrc_horizontal_split', 0)
      cmdSplit = 'split'
    endif
    if opt.Get('vrc_keepalt', 0)
      cmdSplit = 'keepalt ' .. cmdSplit
    endif
    execute 'rightbelow ' .. cmdSplit
    execute 'buffer ' .. buf
    win = win_getid()
  else
    win_gotoid(win)
  endif

  setbufvar(buf, '&buftype', 'nofile')
  setbufvar(buf, '&swapfile', false)
  setbufvar(buf, '&bufhidden', 'hide')
  setbufvar(buf, '&undolevels', -1)
  setbufvar(buf, '&modifiable', 1)
  deletebufline(buf, 1, '$')
  setbufline(buf, 1, lines)
  setbufvar(buf, '&modifiable', 0)

  if opt.Get('vrc_show_command_in_quickfix', 1) && !empty(commands)
    setqflist([], 'r', {
      'title': 'VRC requests',
      'items': mapnew(
        commands,
        (_, value: string): dict<any> => ({'text': value, 'lnum': 0})
      ),
    })
    copen
    win_gotoid(win)
  endif

  if opt.Get('vrc_syntax_highlight_response', 1)
    ApplySyntax(meta)
  else
    syntax clear
  endif

  win_gotoid(origWin)
enddef
