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
var ActiveRun: dict<any> = {}
var PendingRuns: list<dict<any>> = []
var NextAsyncId = 0
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
export def GetOpt(
  optName: string,
  defaultVal: any,
  targetBuf: number = -1
): any
  var curlOpt = get(deprecatedCurlOpts, optName, '')
  var bufferVars: dict<any> = targetBuf < 0 ? b: : getbufvar(targetBuf, '')

  if has_key(bufferVars, optName)
    if !empty(curlOpt)
      DeprecateOpt(optName, curlOpt)
    endif
    return get(bufferVars, optName)
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
export def BuildRequest(
  request: dict<any>,
  targetBuf: number = -1
): dict<any>
  var opts = opt.DictToCurlPairs(opt.GetDefaultCurlOpts(targetBuf))
  opts = parser.MergeCurlOpts(opts, get(request, 'curlOpts', []))

  if GetOpt('vrc_include_response_header', 0, targetBuf)
    && !parser.HasOption(opts, ['-i', '--include'])
    add(opts, {'name': '-i', 'values': []})
  endif

  if GetOpt('vrc_debug', 0, targetBuf)
    && !parser.HasOption(opts, ['-v', '--verbose'])
    add(opts, {'name': '-v', 'values': []})
  endif

  # Consider adding -k only if vrc_ssl_secure is configured (secureSsl > -1).
  var secureSsl = GetOpt('vrc_ssl_secure', -1, targetBuf)
  if request.host =~? '\v^\s*HTTPS://' && secureSsl == 0
    && !parser.HasOption(opts, ['-k', '--insecure'])
    add(opts, {'name': '-k', 'values': []})
  endif

  if GetOpt('vrc_resolve_to_ipv4', 0, targetBuf) && !parser.HasOption(opts, ['--ipv4'])
    add(opts, {'name': '--ipv4', 'values': []})
  endif

  var cookieJar = '' .. GetOpt('vrc_cookie_jar', '', targetBuf)
  if !empty(cookieJar)
    if !parser.HasOption(opts, ['-b', '--cookie'])
      add(opts, {'name': '-b', 'values': [cookieJar]})
    endif
    if !parser.HasOption(opts, ['-c', '--cookie-jar'])
      add(opts, {'name': '-c', 'values': [cookieJar]})
    endif
  endif

  if GetOpt('vrc_follow_redirects', 0, targetBuf) && !parser.HasOption(opts, ['-L', '--location'])
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

  var vrcConnectTimeout = GetOpt('vrc_connect_timeout', 0, targetBuf)
  if vrcConnectTimeout && !parser.HasOption(opts, ['--connect-timeout'])
    add(opts, {
      'name': '--connect-timeout',
      'values': ['' .. vrcConnectTimeout],
    })
  endif

  var vrcMaxTime = GetOpt('vrc_max_time', 0, targetBuf)
  if vrcMaxTime && !parser.HasOption(opts, ['--max-time'])
    add(opts, {'name': '--max-time', 'values': ['' .. vrcMaxTime]})
  endif

  # Suppress curl's progress meter while still showing errors.
  if !parser.HasOption(opts, ['-s', '--silent', '-sS'])
    add(opts, {'name': '-sS', 'values': []})
  endif

  var verbArgs = GetCurlRequestOpt(request.httpVerb, targetBuf)
  var body = empty(request.dataBody)
    ? {'args': [], 'input': ''}
    : GetCurlBody(request, targetBuf)
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
def GetCurlRequestOpt(httpVerb: string, targetBuf: number): list<string>
  if httpVerb ==? 'GET'
    if GetOpt('vrc_allow_get_request_body', 0, targetBuf)
      return ['-X', 'GET']
    endif
    return ['--get']
  elseif httpVerb ==? 'HEAD'
    return ['--head']
  endif
  return ['-X', httpVerb]
enddef

# Resolve a body file reference (@path) relative to the request buffer.
def ResolveBodyFile(spec: string, targetBuf: number): string
  var path = strpart(spec, 1)
  if path == '-'
    return spec
  endif
  if path !~# '^[/\\]' && path !~# '^\a:[\\/]'
    var dir = fnamemodify(bufname(targetBuf < 0 ? '%' : targetBuf), ':p:h')
    path = dir .. '/' .. path
  endif
  return '@' .. simplify(path)
enddef

# Build the body arguments and stdin for the request.
def GetCurlBody(request: dict<any>, targetBuf: number): dict<any>
  var httpVerb: string = request.httpVerb
  var dataLines: list<any> = copy(request.dataBody)
  var preproc = '' .. GetOpt('vrc_body_preprocessor', '', targetBuf)

  var bodyVerbs = ['POST', 'PUT', 'PATCH', 'OPTIONS']
  if index(bodyVerbs, toupper(httpVerb)) >= 0
    if stridx(get(dataLines, 0, ''), '@') == 0
      return {
        'args': ['--data-binary', ResolveBodyFile(dataLines[0], targetBuf)],
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

    if GetOpt('vrc_split_request_body', 0, targetBuf)
      var splitArgs: list<string> = []
      for line in dataLines
        extend(splitArgs, ['--data', line])
      endfor
      return {'args': splitArgs, 'input': ''}
    endif

    var elasticSupport = GetOpt('vrc_elasticsearch_support', 0, targetBuf)
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

  if httpVerb ==? 'GET' && GetOpt('vrc_allow_get_request_body', 0, targetBuf)
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
  if GetOpt('vrc_split_request_body', 0, targetBuf)
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

# --- Asynchronous execution -------------------------------------------------

def AsyncAvailable(): bool
  return has('job') && has('timers')
enddef

def AsyncGetLine(targetBuf: number, lineNum: number): string
  var lines = getbufline(targetBuf, lineNum, lineNum)
  return empty(lines) ? '' : lines[0]
enddef

def AddAsyncError(run: dict<any>, text: string): void
  if !empty(run.outputInfo.chunks)
    var last = run.outputInfo.chunks[-1]
    last.error = empty(last.error) ? text : last.error .. "\n" .. text
  else
    add(run.outputInfo.chunks, {
      'text': '',
      'error': text,
      'hasResponseHeader': false,
    })
  endif
  display.Update(run.outputInfo, false, run.bufnr)
enddef

def FinishAsyncRun(run: dict<any>): void
  if get(run, 'finished', false)
    return
  endif
  run.finished = true
  display.Update(run.outputInfo, true, run.bufnr)
  if get(ActiveRun, 'id', -1) == run.id
    ActiveRun = {}
  endif
  StartQueuedRun()
enddef

def StartQueuedRun(): void
  while !empty(PendingRuns)
    var pending = remove(PendingRuns, 0)
    if !bufexists(pending.bufnr) || !bufloaded(pending.bufnr)
      echom 'VRC: skipping queued request for a closed buffer'
      continue
    endif
    StartAsyncRanges(pending.ranges, pending.bufnr)
    return
  endwhile
enddef

def InitAsyncRange(run: dict<any>): void
  var range = run.ranges[run.rangeIndex]
  run.startLine = range[0]
  run.endLine = range[1]
  run.state = parser.NewState(
    range[0],
    range[1],
    parser.ParseGlobSection(run.bufnr),
    run.bufnr
  )
enddef

export def StartAsyncRanges(
  ranges: list<list<number>>,
  targetBuf: number = -1
): void
  var buf = targetBuf < 0 ? bufnr('%') : targetBuf
  if empty(ranges)
    return
  endif

  if !AsyncAvailable()
    echom 'VRC: async execution is unavailable; running synchronously'
    for range in ranges
      RunQuery(range[0], range[1])
    endfor
    return
  endif

  if !empty(ActiveRun)
    add(PendingRuns, {
      'ranges': deepcopy(ranges),
      'bufnr': buf,
    })
    echom 'VRC: queued behind the current request'
    return
  endif

  NextAsyncId += 1
  var run: dict<any> = {
    'id': NextAsyncId,
    'bufnr': buf,
    'ranges': deepcopy(ranges),
    'rangeIndex': 0,
    'startLine': ranges[0][0],
    'endLine': ranges[0][1],
    'state': {},
    'outputInfo': {'chunks': [], 'commands': []},
    'cancelled': false,
    'finished': false,
    'executed': false,
    'handle': {},
    'timeoutMs': exec.ParseTimeout(GetOpt('vrc_curl_timeout', '1m', buf)),
  }
  InitAsyncRange(run)
  ActiveRun = run
  echo 'VRC: running asynchronously'
  StartNextAsyncRequest(run)
enddef

export def StartAsyncRun(
  startLine: number,
  endLine: number,
  targetBuf: number = -1
): void
  StartAsyncRanges([[startLine, endLine]], targetBuf)
enddef

def StartNextAsyncRequest(run: dict<any>): void
  if run.finished || run.cancelled
    return
  endif
  while run.state.pos > run.endLine
    run.rangeIndex += 1
    if run.rangeIndex >= len(run.ranges)
      FinishAsyncRun(run)
      return
    endif
    InitAsyncRange(run)
  endwhile

  var request = parser.NextRequest(run.state)
  if !request.success
    if !run.executed
      echom request.msg
    endif
    FinishAsyncRun(run)
    return
  endif
  run.executed = true

  var built = BuildRequest(request, run.bufnr)
  if GetOpt('vrc_debug', 0, run.bufnr)
    echom '[Debug] Command: ' .. built.display
    echom '[Debug] Input: ' .. string(built.input)
  endif

  run.timeoutMs = exec.ParseTimeout(
    GetOpt('vrc_curl_timeout', '1m', run.bufnr)
  )
  run.handle = exec.Start(
    built.argv,
    built.input,
    run.timeoutMs,
    (result: dict<any>): void =>
      OnAsyncCurlDone(run, request, built, result)
  )
enddef

def OnAsyncCurlDone(
  run: dict<any>,
  request: dict<any>,
  built: dict<any>,
  result: dict<any>
): void
  if run.finished || run.cancelled
    return
  endif
  run.handle = {}

  var requestOutput = result.out
  var errorText = ''
  if result.cancelled
    errorText = 'VRC: cancelled'
  elseif result.timedout
    errorText = 'VRC: request timed out'
  elseif !empty(result.err)
    errorText = result.err
  elseif result.code != 0
    errorText = 'VRC: curl exited with code ' .. result.code
  endif

  if result.cancelled || result.timedout
    add(run.outputInfo.chunks, {
      'text': requestOutput,
      'error': errorText,
      'hasResponseHeader': built.hasResponseHeader,
    })
    AddAsyncCommand(run, request, built)
    FinishAsyncRun(run)
    return
  endif

  if !empty(request.pipe)
    run.handle = exec.StartShell(
      request.pipe,
      requestOutput,
      run.timeoutMs,
      (piped: dict<any>): void =>
        OnAsyncPipeDone(run, request, built, requestOutput, errorText, piped)
    )
  else
    CompleteAsyncRequest(run, request, built, requestOutput, errorText)
  endif
enddef

def OnAsyncPipeDone(
  run: dict<any>,
  request: dict<any>,
  built: dict<any>,
  requestOutput: string,
  errorText: string,
  piped: dict<any>
): void
  if run.finished || run.cancelled
    return
  endif
  run.handle = {}

  var output = piped.out
  var errors = errorText
  if piped.cancelled
    if !empty(errors)
      errors ..= "\n"
    endif
    errors ..= 'VRC: cancelled'
    add(run.outputInfo.chunks, {
      'text': output,
      'error': errors,
      'hasResponseHeader': built.hasResponseHeader,
    })
    AddAsyncCommand(run, request, built)
    FinishAsyncRun(run)
    return
  endif
  if piped.timedout
    if !empty(errors)
      errors ..= "\n"
    endif
    errors ..= 'VRC: pipe command timed out'
    add(run.outputInfo.chunks, {
      'text': output,
      'error': errors,
      'hasResponseHeader': built.hasResponseHeader,
    })
    AddAsyncCommand(run, request, built)
    FinishAsyncRun(run)
    return
  endif
  if piped.code != 0
    if !empty(errors)
      errors ..= "\n"
    endif
    errors ..= 'VRC: pipe command failed with code ' .. piped.code
  endif

  CompleteAsyncRequest(run, request, built, output, errors)
enddef

def AddAsyncCommand(
  run: dict<any>,
  request: dict<any>,
  built: dict<any>
): void
  if !GetOpt('vrc_show_command', 0, run.bufnr)
    return
  endif
  var commandDisplay = built.display
  if !empty(request.pipe)
    commandDisplay ..= ' ' .. request.pipe
  endif
  add(run.outputInfo.commands, commandDisplay)
enddef

def CompleteAsyncRequest(
  run: dict<any>,
  request: dict<any>,
  built: dict<any>,
  requestOutput: string,
  errorText: string
): void
  add(run.outputInfo.chunks, {
    'text': requestOutput,
    'error': errorText,
    'hasResponseHeader': built.hasResponseHeader,
  })
  AddAsyncCommand(run, request, built)
  display.Update(run.outputInfo, false, run.bufnr)

  var handlers = CollectAsyncHandlers(run, request)
  if empty(handlers)
    AfterAsyncHandlers(run)
  else
    RunAsyncHandlers(run, request, handlers, 0, requestOutput)
  endif
enddef

def CollectAsyncHandlers(
  run: dict<any>,
  request: dict<any>
): list<dict<any>>
  var nextParts = parser.ParseVerbQuery(
    request.lineNum + 1,
    run.endLine,
    run.bufnr
  )
  var nextVerb: number = nextParts[0]
  if nextVerb == 0
    nextVerb = run.endLine
  endif

  var handlers: list<dict<any>> = []
  for i in range(request.lineNum, nextVerb)
    var line = AsyncGetLine(run.bufnr, i)
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
    add(handlers, {'target': cmd[0], 'pattern': cmd[1]})
  endfor
  return handlers
enddef

def RunAsyncHandlers(
  run: dict<any>,
  request: dict<any>,
  handlers: list<dict<any>>,
  index: number,
  input: string
): void
  if run.finished || run.cancelled
    return
  endif
  if index >= len(handlers)
    AfterAsyncHandlers(run)
    return
  endif

  var handler = handlers[index]
  run.handle = exec.StartShell(
    handler.pattern,
    input,
    run.timeoutMs,
    (result: dict<any>): void =>
      OnAsyncHandlerDone(run, request, handlers, index, input, handler, result)
  )
enddef

def OnAsyncHandlerDone(
  run: dict<any>,
  request: dict<any>,
  handlers: list<dict<any>>,
  index: number,
  input: string,
  handler: dict<any>,
  result: dict<any>
): void
  if run.finished || run.cancelled
    return
  endif
  run.handle = {}

  if result.cancelled
    AddAsyncError(run, 'VRC: cancelled')
    FinishAsyncRun(run)
    return
  endif
  if result.timedout
    AddAsyncError(run, 'VRC: handler timed out')
    FinishAsyncRun(run)
    return
  endif

  var target = handler.target
  var output = result.out
  var code = result.code
  if !empty(target) && trim(target) != '?'
    ApplyAsyncHandlerReplacement(run, target, trim(output))
  elseif trim(target) == '?'
    if code != 0
      echohl WarningMsg
      echo 'VRC: handler assertion failed with code ' .. code
      echohl None
      AddAsyncError(run, 'VRC: handler assertion failed')
      FinishAsyncRun(run)
      return
    endif
  else
    add(run.outputInfo.commands, output)
  endif

  RunAsyncHandlers(run, request, handlers, index + 1, input)
enddef

def ApplyAsyncHandlerReplacement(
  run: dict<any>,
  target: string,
  replacement: string
): void
  var allLines = getbufline(run.bufnr, 1, '$')
  var globEnd = parser.GlobSectionEnd(allLines)
  if globEnd > 0
    var globalLines = getbufline(run.bufnr, 1, globEnd)
    var replacedGlobal = mapnew(
      globalLines,
      (_, value: string): string =>
        ReplaceLinePrefix(value, target, replacement)
    )
    setbufline(run.bufnr, 1, replacedGlobal)
  endif

  var blockLines = getbufline(run.bufnr, run.startLine, run.endLine)
  var replacedBlock = mapnew(
    blockLines,
    (_, value: string): string =>
      ReplaceLinePrefix(value, target, replacement)
  )
  setbufline(run.bufnr, run.startLine, replacedBlock)
enddef

def AfterAsyncHandlers(run: dict<any>): void
  if run.finished || run.cancelled
    return
  endif
  run.state.glob = parser.ParseGlobSection(run.bufnr)
  StartNextAsyncRequest(run)
enddef

export def Cancel(): void
  if empty(ActiveRun)
    echom 'VRC: no asynchronous request is running'
    return
  endif

  var run = ActiveRun
  run.cancelled = true
  PendingRuns = []

  if !empty(run.handle) && has_key(run.handle, 'cancel')
    run.handle.cancel()
  endif

  AddAsyncError(run, 'VRC: cancelled')
  FinishAsyncRun(run)
enddef

export def IsRunning(): bool
  return !empty(ActiveRun)
enddef

def RunBlocks(ranges: list<list<number>>, targetBuf: number): void
  if AsyncAvailable() && GetOpt('vrc_async', 0, targetBuf)
    StartAsyncRanges(ranges, targetBuf)
  else
    echo 'VRC: running...'
    for range in ranges
      RunQuery(range[0], range[1])
    endfor
  endif
enddef

def RunBlock(startLine: number, endLine: number, targetBuf: number): void
  RunBlocks([[startLine, endLine]], targetBuf)
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
  outputInfo: dict<any>,
  targetBuf: number = -1
): number
  var verbParts = parser.ParseVerbQuery(resumeFrom, endLine, targetBuf)
  var currVerb: number = verbParts[0]
  var nextParts = parser.ParseVerbQuery(currVerb + 1, endLine, targetBuf)
  var nextVerb: number = nextParts[0]
  if nextVerb == 0
    nextVerb = endLine
  endif

  for i in range(currVerb, nextVerb)
    var line = targetBuf < 0 ? getline(i) : getbufline(targetBuf, i)[0]
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
      var allLines = targetBuf < 0 ? getline(1, '$') : getbufline(targetBuf, 1, '$')
      var globEnd = parser.GlobSectionEnd(allLines)
      if globEnd > 0
        var globalLines = targetBuf < 0
          ? getline(1, globEnd)
          : getbufline(targetBuf, 1, globEnd)
        var replacedGlobal = mapnew(
          globalLines,
          (_, value: string): string =>
            ReplaceLinePrefix(value, cmd[0], replacement)
        )
        if targetBuf < 0
          setline(1, replacedGlobal)
        else
          setbufline(targetBuf, 1, replacedGlobal)
        endif
      endif
      var blockLines = targetBuf < 0
        ? getline(startLine, endLine)
        : getbufline(targetBuf, startLine, endLine)
      var replacedBlock = mapnew(
        blockLines,
        (_, value: string): string =>
          ReplaceLinePrefix(value, cmd[0], replacement)
      )
      if targetBuf < 0
        setline(startLine, replacedBlock)
      else
        setbufline(targetBuf, startLine, replacedBlock)
      endif
    else
      if trim(cmd[0]) == '?'
        if code != 0
          echohl WarningMsg
          echo 'Execution failed at line ' .. i .. ' (code: ' .. code .. ')'
          echohl None
          if targetBuf < 0 || targetBuf == bufnr('%')
            cursor(i, 1)
          endif
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

# Run request blocks.  With no arguments, run the block under the cursor.
# With a range, run every block that intersects the range.
export def Query(firstLine: number = -1, lastLine: number = -1): void
  # We will jump around; save the current win line to restore the view.
  var curWinLine = winline()
  var executed = false

  if firstLine < 0
    var curPos = getpos('.')
    if curPos[1] <= LineNumGlobSectionDelim()
      echom 'Cannot execute global section'
      return
    endif

    var block = LineNumsRequestBlock()
    if block[0] == 0
      RestoreWinLine(curWinLine)
      echom 'Missing host/block start'
      return
    endif
    RunBlock(block[0], block[1], bufnr('%'))
    executed = true
  else
    var endLine = lastLine < firstLine ? firstLine : lastLine
    var blocks: list<list<number>> = []
    for block in parser.BlockRanges(getline(1, '$'))
      if block[1] < firstLine || block[0] > endLine
        continue
      endif
      add(blocks, block)
    endfor
    if !empty(blocks)
      RunBlocks(blocks, bufnr('%'))
      executed = true
    endif
    if !executed
      echom 'No request block in range'
    endif
  endif

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
    .. ' <Plug>(vrc-query)'
  execute 'nnoremap <buffer> ' .. triggerKey
    .. ' <Plug>(vrc-query)'
  execute 'inoremap <buffer> ' .. triggerKey
    .. ' <Plug>(vrc-query)'

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
