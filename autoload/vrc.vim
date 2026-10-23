vim9script

# Vim REST Console - core implementation.
#
# This module is loaded on demand by the ftplugin, plugin commands, and the
# compatibility wrappers.  Public entry points are Query(), Map(), and
# HandleResponse().

import autoload 'vrc/opt.vim' as opt
import autoload 'vrc/parser.vim' as parser
import autoload 'vrc/exec.vim' as exec
import autoload 'vrc/display.vim' as display

var deprecatedMessages: list<string> = []
const deprecatedCurlOpts: dict<string> = {
  'vrc_connect_timeout': '--connect-timeout',
  'vrc_cookie_jar': '-b and -c',
  'vrc_follow_redirects': '-L',
  'vrc_include_response_header': '-i',
  'vrc_max_time': '--max-time',
  'vrc_resolve_to_ipv4': '--ipv4',
  'vrc_ssl_secure': '-k',
}

# Get a VRC option.  Use the given default value if the option is not found.
export def GetOpt(optName: string, defaultVal: any): any
  var curlOpt = get(deprecatedCurlOpts, optName, '')

  if has_key(b:, optName)
    if !empty(curlOpt)
      DeprecateOpt(optName, curlOpt)
    endif
    return get(b:, optName)
  endif
  if has_key(g:, optName)
    if !empty(curlOpt)
      DeprecateOpt(optName, curlOpt)
    endif
    return get(g:, optName)
  endif
  return defaultVal
enddef

# Handle a deprecated option.
def DeprecateOpt(optName: string, forOpt: string): void
  var msg = 'Option `' .. optName .. '` is deprecated and will be removed. '
    .. 'Use the cUrl option(s) ' .. forOpt .. ' instead.'

  echohl WarningMsg
  echom msg
  echohl None
  add(deprecatedMessages, msg)
enddef

# Get the first and last line numbers of the request block enclosing the
# cursor.
export def LineNumsRequestBlock(): list<number>
  return parser.FindBlock(getline(1, '$'), line('.'))
enddef

# Get the line number of the global section delimiter.
export def LineNumGlobSectionDelim(): number
  return parser.GlobSectionEnd(getline(1, '$'))
enddef

# Build a curl invocation for one request.
export def BuildRequest(request: dict<any>): dict<any>
  var opts = opt.DictToCurlPairs(opt.GetDefaultCurlOpts())
  opts = parser.MergeCurlOpts(opts, get(request, 'curlOpts', []))

  if GetOpt('vrc_include_response_header', 0)
    && !parser.HasOption(opts, ['-i', '--include'])
    add(opts, {'name': '-i', 'values': []})
  endif

  if GetOpt('vrc_debug', 0)
    && !parser.HasOption(opts, ['-v', '--verbose'])
    add(opts, {'name': '-v', 'values': []})
  endif

  # Consider adding -k only if vrc_ssl_secure is configured (secureSsl > -1).
  var secureSsl = GetOpt('vrc_ssl_secure', -1)
  if request.host =~? '\v^\s*HTTPS://' && secureSsl == 0
    && !parser.HasOption(opts, ['-k', '--insecure'])
    add(opts, {'name': '-k', 'values': []})
  endif

  if GetOpt('vrc_resolve_to_ipv4', 0) && !parser.HasOption(opts, ['--ipv4'])
    add(opts, {'name': '--ipv4', 'values': []})
  endif

  var cookieJar = '' .. GetOpt('vrc_cookie_jar', '')
  if !empty(cookieJar)
    if !parser.HasOption(opts, ['-b', '--cookie'])
      add(opts, {'name': '-b', 'values': [cookieJar]})
    endif
    if !parser.HasOption(opts, ['-c', '--cookie-jar'])
      add(opts, {'name': '-c', 'values': [cookieJar]})
    endif
  endif

  if GetOpt('vrc_follow_redirects', 0) && !parser.HasOption(opts, ['-L', '--location'])
    add(opts, {'name': '-L', 'values': []})
  endif

  var headerValues: list<string> = []
  var headers: dict<any> = get(request, 'headers', {})
  for key in keys(headers)
    add(headerValues, key .. ': ' .. headers[key])
  endfor
  if !empty(headerValues)
    parser.AppendOption(opts, '-H', headerValues)
  endif

  var vrcConnectTimeout = GetOpt('vrc_connect_timeout', 0)
  if vrcConnectTimeout && !parser.HasOption(opts, ['--connect-timeout'])
    add(opts, {
      'name': '--connect-timeout',
      'values': ['' .. vrcConnectTimeout],
    })
  endif

  var vrcMaxTime = GetOpt('vrc_max_time', 0)
  if vrcMaxTime && !parser.HasOption(opts, ['--max-time'])
    add(opts, {'name': '--max-time', 'values': ['' .. vrcMaxTime]})
  endif

  # Suppress curl's progress meter while still showing errors.
  if !parser.HasOption(opts, ['-s', '--silent', '-sS'])
    add(opts, {'name': '-sS', 'values': []})
  endif

  var verbArgs = GetCurlRequestOpt(request.httpVerb)
  var body = empty(request.dataBody)
    ? {'args': [], 'input': ''}
    : GetCurlBody(request)
  var argv = ['curl']
    + parser.PairsToArgs(opts)
    + verbArgs
    + body.args
    + [request.host .. request.requestPath]

  return {
    'argv': argv,
    'input': body.input,
    'display': exec.CommandString(argv),
    'hasResponseHeader': parser.HasOption(opts, ['-i', '--include']),
  }
enddef

# Get the cUrl arguments for the request method.
def GetCurlRequestOpt(httpVerb: string): list<string>
  if httpVerb ==? 'GET'
    if GetOpt('vrc_allow_get_request_body', 0)
      return ['-X', 'GET']
    endif
    return ['--get']
  elseif httpVerb ==? 'HEAD'
    return ['--head']
  endif
  return ['-X', httpVerb]
enddef

# Resolve a body file reference (@path) relative to the request buffer.
def ResolveBodyFile(spec: string): string
  var path = strpart(spec, 1)
  if path == '-'
    return spec
  endif
  if path !~# '^[/\\]' && path !~# '^\a:[\\/]'
    var dir = fnamemodify(bufname('%'), ':p:h')
    path = dir .. '/' .. path
  endif
  return '@' .. simplify(path)
enddef

# Build the body arguments and stdin for the request.
def GetCurlBody(request: dict<any>): dict<any>
  var httpVerb: string = request.httpVerb
  var dataLines: list<any> = copy(request.dataBody)
  var preproc = '' .. GetOpt('vrc_body_preprocessor', '')

  var bodyVerbs = ['POST', 'PUT', 'PATCH', 'OPTIONS']
  if index(bodyVerbs, toupper(httpVerb)) >= 0
    if stridx(get(dataLines, 0, ''), '@') == 0
      return {
        'args': ['--data-binary', ResolveBodyFile(dataLines[0])],
        'input': '',
      }
    endif

    if !empty(preproc)
      var pre = exec.Shell(preproc, join(dataLines, "\n"))
      if pre.code != 0
        echom 'VRC: body preprocessor failed with code ' .. pre.code
      endif
      dataLines = split(pre.out, '\n', true)
    endif

    if GetOpt('vrc_split_request_body', 0)
      var splitArgs: list<string> = []
      for line in dataLines
        extend(splitArgs, ['--data', line])
      endfor
      return {'args': splitArgs, 'input': ''}
    endif

    var elasticSupport = GetOpt('vrc_elasticsearch_support', 0)
    if elasticSupport && match(request.requestPath, '/_bulk\|/_msearch') > -1
      return {
        'args': ['--data-binary', join(dataLines, "\n") .. "\n"],
        'input': '',
      }
    endif

    return {
      'args': ['--data-binary', '@-'],
      'input': join(dataLines, ''),
    }
  endif

  if httpVerb ==? 'GET' && GetOpt('vrc_allow_get_request_body', 0)
    if !empty(preproc)
      var pre = exec.Shell(preproc, join(dataLines, "\n"))
      if pre.code != 0
        echom 'VRC: body preprocessor failed with code ' .. pre.code
      endif
      dataLines = split(pre.out, '\n', true)
    endif
    return {
      'args': ['--data-binary', '@-'],
      'input': join(dataLines, ''),
    }
  endif

  # Other verbs send data as query parameters.
  var args: list<string> = []
  if index(['HEAD', 'DELETE'], toupper(httpVerb)) >= 0
    add(args, '-G')
  endif
  if GetOpt('vrc_split_request_body', 0)
    for line in dataLines
      extend(args, ['--data-urlencode', line])
    endfor
  else
    extend(args, ['--data-urlencode', join(dataLines, '')])
  endif
  return {'args': args, 'input': ''}
enddef

# Run a REST request between the given lines.
export def RunQuery(startLine: number, endLine: number): void
  var globSection = parser.ParseGlobSection()
  var state = parser.NewState(startLine, endLine, globSection)
  var outputInfo: dict<any> = {
    'chunks': [],
    'commands': [],
  }

  # The while loop supports multiple requests using consecutive verbs.
  var shouldShowCommand = GetOpt('vrc_show_command', 0)
  var shouldDebug = GetOpt('vrc_debug', 0)
  var timeoutMs = exec.ParseTimeout(GetOpt('vrc_curl_timeout', '1m'))
  var executed = false
  while state.pos <= endLine
    var request = parser.NextRequest(state)
    if !request.success
      # A trailing comment-only line must not turn into an error after a
      # successful request.
      if !executed
        echom request.msg
      endif
      break
    endif
    executed = true

    var built = BuildRequest(request)
    if shouldDebug
      echom '[Debug] Command: ' .. built.display
      echom '[Debug] Input: ' .. string(built.input)
    endif
    redraw!

    var result = exec.Run(built.argv, built.input, timeoutMs)
    var requestOutput = result.out
    var errorText = ''
    if result.timedout
      errorText ..= 'VRC: request timed out'
    endif
    if !empty(result.err)
      if !empty(errorText)
        errorText ..= "\n"
      endif
      errorText ..= result.err
    elseif result.code != 0 && !result.timedout
      errorText = 'VRC: curl exited with code ' .. result.code
    endif
    if !empty(request.pipe)
      var piped = exec.Shell(request.pipe, requestOutput)
      requestOutput = piped.out
      if piped.code != 0
        if !empty(errorText)
          errorText ..= "\n"
        endif
        errorText ..= 'VRC: pipe command failed with code ' .. piped.code
      endif
    endif

    add(outputInfo['chunks'], {
      'text': requestOutput,
      'error': errorText,
      'hasResponseHeader': built.hasResponseHeader,
    })

    var commandDisplay = built.display
    if !empty(request.pipe)
      commandDisplay ..= ' ' .. request.pipe
    endif
    if shouldShowCommand
      add(outputInfo['commands'], commandDisplay)
    endif

    if ProcessResponseHandlers(
      startLine,
      request.lineNum,
      endLine,
      requestOutput,
      outputInfo
    ) != 0
      break
    endif
    globSection = parser.ParseGlobSection()
    state.glob = globSection
  endwhile

  display.Show(outputInfo, {})
enddef

# Replace the remainder of line with replacement when it starts with target.
def ReplaceLinePrefix(
  line: string,
  target: string,
  replacement: string
): string
  if stridx(line, target) == 0
    return target .. replacement
  endif
  return line
enddef

# Handle output of a request.
export def ProcessResponseHandlers(
  startLine: number,
  resumeFrom: number,
  endLine: number,
  input: string,
  outputInfo: dict<any>
): number
  var verbParts = parser.ParseVerbQuery(resumeFrom, endLine)
  var currVerb: number = verbParts[0]
  var nextParts = parser.ParseVerbQuery(currVerb + 1, endLine)
  var nextVerb: number = nextParts[0]
  if nextVerb == 0
    nextVerb = endLine
  endif

  for i in range(currVerb, nextVerb)
    var line = getline(i)
    if match(line, '^#>.*<<.\+') != 0
      continue
    endif
    var parts = split(line, '#>\|<<', true)
    if len(parts) < 3
      continue
    endif
    var cmd = mapnew(
      parts[1 : 2],
      (_, value: string): string => trim(value, ' ', 1)
    )
    var result = exec.Shell(cmd[1], input)
    var output = result.out
    var code = result.code
    if !empty(cmd[0]) && trim(cmd[0]) != '?'
      var replacement = trim(output)
      var globEnd = LineNumGlobSectionDelim()
      if globEnd > 0
        setline(
          1,
          mapnew(
            getline(1, globEnd),
            (_, value: string): string =>
              ReplaceLinePrefix(value, cmd[0], replacement)
          )
        )
      endif
      setline(
        startLine,
        mapnew(
          getline(startLine, endLine),
          (_, value: string): string =>
            ReplaceLinePrefix(value, cmd[0], replacement)
        )
      )
    else
      if trim(cmd[0]) == '?'
        if code != 0
          echohl WarningMsg
          echo 'Execution failed at line ' .. i .. ' (code: ' .. code .. ')'
          echohl None
          cursor(i, 1)
          return code
        endif
      else
        # Trace handlers always report their output, regardless of
        # vrc_show_command.
        add(outputInfo['commands'], output)
      endif
    endif
  endfor
  return 0
enddef

# Restore the win line to the given previous line.
def RestoreWinLine(prevLine: number): void
  var offset = winline() - prevLine
  if offset == 0
    return
  elseif offset > 0
    execute 'normal! ' .. offset .. "\<C-e>"
  else
    execute 'normal! ' .. -offset .. "\<C-y>"
  endif
enddef

# Run a request block that encloses the cursor.
export def Query(): void
  # We will jump around; save the current win line to restore the view.
  var curWinLine = winline()
  var curPos = getpos('.')
  if curPos[1] <= LineNumGlobSectionDelim()
    echom 'Cannot execute global section'
    return
  endif

  # Determine the REST request block to process.
  var block = LineNumsRequestBlock()
  var blockStart = block[0]
  var blockEnd = block[1]
  if blockStart == 0
    RestoreWinLine(curWinLine)
    echom 'Missing host/block start'
    return
  endif

  # Parse and execute the query.
  RunQuery(blockStart, blockEnd)
  RestoreWinLine(curWinLine)

  # Display deprecated messages if any.
  if !empty(deprecatedMessages)
    for msg in deprecatedMessages
      echohl WarningMsg
      echo msg
      echohl None
    endfor
    deprecatedMessages = []
  endif
enddef

# Handle the content of the output buffer.
export def HandleResponse(
  firstLine: number = line('.'),
  lastLine: number = -1
): void
  var endLine = lastLine < 0 ? firstLine : lastLine
  for lnum in range(firstLine, endLine)
    var line = getline(lnum)
    if match(line, '^#%.*<<.\+') != 0
      continue
    endif
    var parts = split(line, '#%\|<<', true)
    if len(parts) < 3
      continue
    endif
    var cmd = mapnew(
      parts[1 : 2],
      (_, value: string): string => trim(value, ' ', 1)
    )
    var outputBufferName = '' .. GetOpt(
      'vrc_output_buffer_name',
      '__REST_response__'
    )
    var outputBuffer = bufnr(outputBufferName)
    if outputBuffer == -1
      continue
    endif
    var inputLines = getbufline(outputBuffer, 1, '$')
    if empty(inputLines)
      continue
    endif
    var input = join(inputLines, "\n")
    var result = exec.Shell(cmd[1], input)
    var output = result.out
    var code = result.code
    if !empty(cmd[0]) && trim(cmd[0]) != '?'
      var replacement = trim(output)
      setline(
        1,
        mapnew(
          getline(1, '$'),
          (_, value: string): string =>
            ReplaceLinePrefix(value, cmd[0], replacement)
        )
      )
    else
      if trim(cmd[0]) == '?'
        output = code == 0 ? 'True' : 'False'
      endif
      setqflist(
        [],
        lnum == firstLine ? 'r' : 'a',
        {
          'items': mapnew(
            split(output, '\n'),
            (_, value: string): dict<any> => ({'text': value, 'lnum': lnum})
          ),
        }
      )
      var currWin = winnr()
      copen
      execute ':' .. currWin .. 'wincmd w'
    endif
  endfor
enddef

# Do the key map.
export def Map(): void
  var triggerKey = '' .. GetOpt('vrc_trigger', '<C-j>')
  execute 'vnoremap <buffer> ' .. triggerKey
    .. ' :call vrc#Query()<CR>'
  execute 'nnoremap <buffer> ' .. triggerKey
    .. ' :call vrc#Query()<CR>'
  execute 'inoremap <buffer> ' .. triggerKey
    .. ' <Esc>:call vrc#Query()<CR>'

  b:vrc_mapped_trigger = triggerKey
  var undo = get(b:, 'undo_ftplugin', '')
  if !empty(undo)
    undo ..= ' | '
  endif
  undo ..= 'call vrc#UndoMap()'
  b:undo_ftplugin = undo
enddef

# Remove the buffer-local trigger mappings installed by Map().
export def UndoMap(): void
  var triggerKey = get(b:, 'vrc_mapped_trigger', '')
  if empty(triggerKey)
    return
  endif
  execute 'silent! nunmap <buffer> ' .. triggerKey
  execute 'silent! vunmap <buffer> ' .. triggerKey
  execute 'silent! iunmap <buffer> ' .. triggerKey
  unlet b:vrc_mapped_trigger
enddef
