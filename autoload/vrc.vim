vim9script

# Vim REST Console - core implementation.
#
# This module is loaded on demand by the ftplugin, plugin commands, and the
# compatibility wrappers.  Public entry points are Query(), Map(), and
# HandleResponse().

import autoload 'vrc/opt.vim' as opt

const autoFormatResponsePatterns: dict<string> = {
  'json': 'python -m json.tool',
  'xml': 'xmllint --format -',
}

const globDelim = '\v^--\s*$'
const commentDelim = '\c\v^\s*(#|//)'
const blockDelimiter = '\c\v^\s*HTTPS?://|^--\s*$'

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

# The command runner is a seam for tests and for the future job-based
# execution backend.  It receives the complete shell command and returns its
# output.
var CommandRunner: func(string): string = (cmd: string): string => system(cmd)

# Properly escape a string for use in Windows and non-Windows shells.
def Shellescape(val: string): string
  if has('win32')
    return '"' .. substitute(val, '["&\\]', '\\&', 'g') .. '"'
  endif
  return shellescape(val)
enddef

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

# Get a value from a VRC dictionary option.
def GetDict(dictName: string, key: string, defaults: dict<string>): string
  for scope in [b:, g:]
    if has_key(scope, dictName)
      var dictValue: any = scope[dictName]
      if type(dictValue) == v:t_dict && has_key(dictValue, key)
        return dictValue[key]
      endif
    endif
  endfor
  return get(defaults, key, '')
enddef

# Get the first and last line numbers of the request block enclosing the
# cursor.
export def LineNumsRequestBlock(): list<number>
  var curPos = getpos('.')
  var blockStart = 0
  var blockEnd = 0
  var lineNumGlobDelim = LineNumGlobSectionDelim()

  # Find the start of the enclosing request block.
  normal! $
  blockStart = search(blockDelimiter, 'bn')
  if blockStart == 0 || blockStart > curPos[1] || blockStart <= lineNumGlobDelim
    cursor(curPos[1 :])
    return [0, 0]
  endif

  # Find the start of the next request block.
  blockEnd = search(blockDelimiter, 'n') - 1
  if blockEnd <= blockStart
    blockEnd = line('$')
  endif
  cursor(curPos[1 :])
  return [blockStart, blockEnd]
enddef

# Get the line number of the global section delimiter.
export def LineNumGlobSectionDelim(): number
  var curPos = getpos('.')
  normal! gg
  var lineNum = search(globDelim, 'cn')
  cursor(curPos[1 :])
  return lineNum
enddef

# Parse a host between the given line numbers (inclusive end).
export def ParseHost(startLine: number, endLine: number): list<any>
  if endLine < startLine
    return [0, '']
  endif
  var curPos = getpos('.')
  cursor(startLine, 1)
  var lineNum = search('\v\c^\s*HTTPS?://', 'cn', endLine)
  cursor(curPos[1 :])
  if lineNum == 0
    return [lineNum, '']
  endif
  return [lineNum, trim(getline(lineNum))]
enddef

# Parse the query.
export def ParseVerbQuery(startLine: number, endLine: number): list<any>
  var curPos = getpos('.')
  cursor(startLine, 1)
  var lineNum = search(
    '\c\v^(GET|POST|PUT|DELETE|HEAD|PATCH|OPTIONS|TRACE)\s+',
    'cn',
    endLine
  )
  cursor(curPos[1 :])
  if lineNum == 0
    return [lineNum, '']
  endif
  return [lineNum, trim(getline(lineNum))]
enddef

# Parse a pipe command.
export def ParsePipe(startLine: number, endLine: number): string
  var pipe = ''
  if endLine < startLine
    return ''
  endif

  var lineBuf = getline(startLine, endLine)
  for line in lineBuf
    var trimmed = trim(line)
    if trimmed == '' || trimmed =~? commentDelim || trimmed =~? '\v^--?\w+'
      continue
    endif
    if trimmed =~ '^|'
      pipe = trimmed
    endif
  endfor
  return pipe
enddef

# Parse header options between the given line numbers (inclusive end).
export def ParseHeaders(startLine: number, endLine: number): dict<any>
  var contentTypeOpt = GetOpt('vrc_header_content_type', 'application/json')
  var headers: dict<any> = {'content-type': contentTypeOpt}
  if endLine < startLine
    return headers
  endif

  var lineBuf = getline(startLine, endLine)
  for line in lineBuf
    var trimmed = trim(line)
    if trimmed =~ '^|' || trimmed == '' || trimmed =~? commentDelim
      || trimmed =~? '\v^--?\w+'
      continue
    endif
    var sepIdx = stridx(trimmed, ':')
    if sepIdx > 0
      var key = tolower(trim(strpart(trimmed, 0, sepIdx)))
      if !empty(key)
        headers[key] = trim(strpart(trimmed, sepIdx + 1))
      endif
    endif
  endfor
  return headers
enddef

# Parse values in the global section.
export def ParseVals(startLine: number, endLine: number): dict<any>
  var vals: dict<any> = {}
  if endLine < startLine
    return vals
  endif

  var lineBuf = getline(startLine, endLine)
  for line in lineBuf
    var trimmed = trim(line)
    if trimmed =~ '^|' || trimmed == '' || trimmed =~? commentDelim
      continue
    endif
    var sepIdx = stridx(trimmed, '=')
    if sepIdx > 0
      var key = trim(strpart(trimmed, 0, sepIdx))
      var val = trim(strpart(trimmed, sepIdx + 1))
      if !empty(key)
        if strpart(val, 0, 1) == '$'
          vals[key] = expand(val)
        else
          vals[key] = val
        endif
      endif
    endif
  endfor
  return vals
enddef

# Substitute :name variables in one pass.
export def SubstituteVars(text: string, vals: dict<any>): string
  if empty(vals)
    return text
  endif

  var keys = sort(
    keys(vals),
    (a: string, b: string): number => strlen(b) - strlen(a)
  )
  var escapedKeys = mapnew(
    keys,
    (_, key: string): string => escape(key, '\.*$^~[]\\')
  )
  var pattern = ':\%(' .. join(escapedKeys, '\|') .. '\)'
  return substitute(
    text,
    pattern,
    '\=get(vals, strpart(submatch(0), 1), submatch(0))',
    'g'
  )
enddef

# Parse the global section.
export def ParseGlobSection(): dict<any>
  var globSection: dict<any> = {
    'host': '',
    'headers': {},
    'curlOpts': {},
    'vals': {},
    'pipe': '',
  }

  # Search for the line of the global section delimiter.
  var lastLine = LineNumGlobSectionDelim()
  if lastLine == 0
    return globSection
  endif

  # Parse the global host.
  var hostParts = ParseHost(1, lastLine - 1)
  var hostLine: number = hostParts[0]
  var host: string = hostParts[1]

  # Parse global headers.
  var headers = ParseHeaders(hostLine + 1, lastLine - 1)

  # Parse curl options.
  var curlOpts = ParseCurlOpts(hostLine + 1, lastLine - 1)

  # Parse global vals.
  var vals = ParseVals(hostLine + 1, lastLine - 1)

  # Parse the pipe command.
  var pipe = ParsePipe(hostLine + 1, lastLine - 1)

  globSection = {
    'host': host,
    'headers': headers,
    'curlOpts': curlOpts,
    'vals': vals,
    'pipe': pipe,
  }
  return globSection
enddef

# Parse the specified cUrl options.
export def ParseCurlOpts(fromLine: number, toLine: number): dict<any>
  var curlOpts: dict<any> = {}
  for line in getline(fromLine, toLine)
    var trimmed = trim(line)
    if trimmed !~? '\v^--?\w+'
      continue
    endif
    var parts = split(trimmed, '\v\s', false)
    if empty(parts)
      continue
    endif
    var copt = parts[0]
    var vals = len(parts) > 1 ? parts[1 :] : []
    if !has_key(curlOpts, copt)
      curlOpts[copt] = []
    endif
    if !empty(vals)
      add(curlOpts[copt], join(vals, ' '))
    endif
  endfor
  return curlOpts
enddef

# Parse the request block.
export def ParseRequest(
  startLine: number,
  resumeFrom: number,
  endLine: number,
  globSection: dict<any>
): dict<any>
  # Parse host.
  var hostParts = ParseHost(startLine, endLine)
  var lineNumHost: number = hostParts[0]
  var host: string = hostParts[1]
  if lineNumHost == 0
    host = get(globSection, 'host', '')
    lineNumHost = startLine
  endif
  if empty(host)
    return {
      'success': false,
      'msg': 'Missing host',
    }
  endif

  # Parse the HTTP verb query.
  var verbParts = ParseVerbQuery(resumeFrom, endLine)
  var lineNumVerb: number = verbParts[0]
  var restQuery: string = verbParts[1]
  if lineNumVerb == 0
    return {
      'success': false,
      'msg': 'Missing query',
    }
  endif

  # Parse the next HTTP verb query.
  var nextResumeFrom = lineNumVerb + 1
  var nextVerbParts = ParseVerbQuery(lineNumVerb + 1, endLine)
  var lineNumNextVerb: number = nextVerbParts[0]
  if lineNumNextVerb == 0
    nextResumeFrom = endLine + 1
    lineNumNextVerb = endLine + 1
  endif

  # Parse headers if any and merge with global headers.
  var localHeaders = ParseHeaders(lineNumHost + 1, lineNumVerb - 1)
  var headers: dict<any> = deepcopy(get(globSection, 'headers', {}))
  extend(headers, localHeaders)

  # Parse curl options; local opts overwrite global opts when merged.
  var localCurlOpts = ParseCurlOpts(lineNumHost + 1, lineNumVerb - 1)
  var curlOpts: dict<any> = deepcopy(get(globSection, 'curlOpts', {}))
  extend(curlOpts, localCurlOpts)

  # Parse local pipe and use global pipe if empty.
  var pipe = ParsePipe(lineNumHost + 1, lineNumVerb - 1)
  if pipe == ''
    pipe = get(globSection, 'pipe', '')
  endif

  var vals: dict<any> = get(globSection, 'vals', {})

  # Parse HTTP verb, query path, and data body.
  var queryParts = split(restQuery, '\v\s', false)
  var httpVerb: string = queryParts[0]
  var queryPath = join(queryParts[1 :], '')
  var dataBody = getline(lineNumVerb + 1, lineNumNextVerb - 1)

  # Search and replace values in queryPath, dataBody, and headers.
  queryPath = SubstituteVars(queryPath, vals)
  dataBody = mapnew(
    dataBody,
    (_, value: string): string => SubstituteVars(value, vals)
  )
  headers = mapnew(
    headers,
    (_, value: string): string => SubstituteVars(value, vals)
  )

  # Filter out comment and blank lines.
  dataBody = filter(
    dataBody,
    (_, value: string): bool =>
      value !~? '\v^\s*(#|//).*$|\v^\s*$'
  )

  # Some might need leading/trailing spaces in body rows.
  return {
    'success': true,
    'resumeFrom': nextResumeFrom,
    'msg': '',
    'host': host,
    'headers': headers,
    'curlOpts': curlOpts,
    'httpVerb': httpVerb,
    'requestPath': queryPath,
    'dataBody': dataBody,
    'pipe': pipe,
  }
enddef

# Construct the cUrl command given the request.
export def GetCurlCommand(request: dict<any>): list<any>
  # Construct curl args.
  var curlOpts: dict<any> = opt.GetDefaultCurlOpts()
  var localOpts: dict<any> = get(request, 'curlOpts', {})
  extend(curlOpts, localOpts)

  var vrcIncludeHeader = GetOpt('vrc_include_response_header', 0)
  if vrcIncludeHeader && !opt.DictHasKeys(curlOpts, ['-i', '--include'])
    curlOpts['-i'] = ''
  endif

  var vrcDebug = GetOpt('vrc_debug', 0)
  if vrcDebug && !has_key(curlOpts, '-v')
    curlOpts['-v'] = ''
  endif

  # Consider adding -k only if vrc_ssl_secure is configured (secureSsl > -1).
  var secureSsl = GetOpt('vrc_ssl_secure', -1)
  if request.host =~? '\v^\s*HTTPS://' && secureSsl == 0
    && !has_key(curlOpts, '-k')
    curlOpts['-k'] = ''
  endif

  # Add --ipv4.
  var resolveToIpv4 = GetOpt('vrc_resolve_to_ipv4', 0)
  if resolveToIpv4 && !has_key(curlOpts, '--ipv4')
    curlOpts['--ipv4'] = ''
  endif

  # Add --cookie-jar.
  var cookieJar = GetOpt('vrc_cookie_jar', '')
  if !empty(cookieJar)
    if !has_key(curlOpts, '-b')
      curlOpts['-b'] = cookieJar
    endif
    if !has_key(curlOpts, '-c')
      curlOpts['-c'] = cookieJar
    endif
  endif

  # Add -L option to enable redirects.
  var locationEnabled = GetOpt('vrc_follow_redirects', 0)
  if locationEnabled && !has_key(curlOpts, '-L')
    curlOpts['-L'] = ''
  endif

  # Add headers.  Copy the existing -H list first so the user's
  # g:vrc_curl_opts is never mutated.
  var headerOpt: any = get(curlOpts, '-H', '')
  if type(headerOpt) == v:t_list
    curlOpts['-H'] = copy(headerOpt)
  elseif type(headerOpt) == v:t_string && !empty(headerOpt)
    curlOpts['-H'] = [headerOpt]
  else
    curlOpts['-H'] = []
  endif
  var headers: dict<any> = get(request, 'headers', {})
  for key in keys(headers)
    add(curlOpts['-H'], key .. ': ' .. headers[key])
  endfor

  # Timeout options.
  var vrcConnectTimeout = GetOpt('vrc_connect_timeout', 0)
  if vrcConnectTimeout && !has_key(curlOpts, '--connect-timeout')
    curlOpts['--connect-timeout'] = vrcConnectTimeout
  endif

  var vrcMaxTime = GetOpt('vrc_max_time', 0)
  if vrcMaxTime && !has_key(curlOpts, '--max-time')
    curlOpts['--max-time'] = vrcMaxTime
  endif

  # Convert cUrl options to command line arguments.
  var curlArgs = opt.DictToCurlArgs(curlOpts)
  curlArgs = mapnew(
    curlArgs,
    (_, value: string): string => EscapeCurlOpt(value)
  )

  # Add HTTP verb.
  add(curlArgs, GetCurlRequestOpt(request.httpVerb))

  # Add data body.
  if !empty(request.dataBody)
    add(curlArgs, GetCurlDataArgs(request))
  endif
  var vrcCurlTimeout = '' .. GetOpt('vrc_curl_timeout', '1m')
  return [
    'timeout ' .. vrcCurlTimeout .. ' curl ' .. join(curlArgs) .. ' '
      .. Shellescape(request.host .. request.requestPath),
    curlOpts,
  ]
enddef

# Helper function to shell-escape cUrl options.
def EscapeCurlOpt(val: string): string
  return val !~ '\v^-' ? Shellescape(val) : val
enddef

# Get the cUrl option for the request method (--get, --head, -X <verb>...).
def GetCurlRequestOpt(httpVerb: string): string
  if httpVerb ==? 'GET'
    if GetOpt('vrc_allow_get_request_body', 0)
      return '-X GET'
    endif
    return '--get'
  elseif httpVerb ==? 'HEAD'
    return '--head'
  endif
  return '-X ' .. httpVerb
enddef

# Get the cUrl option to include a data body (--data, --data-urlencode...).
def GetCurlDataArgs(request: dict<any>): string
  var httpVerb: string = request.httpVerb
  var dataLines: list<any> = request.dataBody

  var preproc = '' .. GetOpt('vrc_body_preprocessor', '')

  # These verbs should have the request body passed as POST params.
  if httpVerb ==? 'POST'
    || httpVerb ==? 'PUT'
    || httpVerb ==? 'PATCH'
    || httpVerb ==? 'OPTIONS'
    # If data is loaded from a file.
    if stridx(get(dataLines, 0, ''), '@') == 0
      return '--data-binary ' .. Shellescape(dataLines[0])
    endif

    # Call the body preprocessor if set.
    if preproc != ''
      dataLines = systemlist(preproc, join(dataLines, "\n"))
    endif

    # If the request body is split line by line.
    if GetOpt('vrc_split_request_body', 0)
      dataLines = mapnew(
        dataLines,
        (_, value: string): string => '--data ' .. Shellescape(value)
      )
      return join(dataLines)
    endif

    # If ElasticSearch support is on and it is a _bulk request.
    var elasticSupport = GetOpt('vrc_elasticsearch_support', 0)
    if elasticSupport && match(request.requestPath, '/_bulk\|/_msearch') > -1
      # shellescape also escapes \n (<NL>) to \\n; replace it back.
      return '--data ' .. substitute(
        Shellescape(join(dataLines, "\n") .. "\n"),
        '\\\n',
        "\n",
        'g'
      )
    endif

    # Otherwise, just join data using empty space.
    return '--data ' .. Shellescape(join(dataLines, ''))
  endif

  # If verb is GET and GET request body is allowed.
  if httpVerb ==? 'GET' && GetOpt('vrc_allow_get_request_body', 0)
    # Call the body preprocessor if set.
    if preproc != ''
      dataLines = systemlist(preproc, join(dataLines, "\n"))
    endif
    return '--data ' .. Shellescape(join(dataLines, ''))
  endif

  # For other cases, the request body is passed as GET params.
  if GetOpt('vrc_split_request_body', 0)
    # If the request body is split, URL-encode each line.
    dataLines = mapnew(
      dataLines,
      (_, value: string): string =>
        '--data-urlencode ' .. Shellescape(value)
    )
    return join(dataLines)
  endif
  # Otherwise, URL-encode and send the request body as a whole.
  return '--data-urlencode ' .. Shellescape(join(dataLines, ''))
enddef

# Display output in the given buffer name.
def DisplayOutput(
  tmpBufName: string,
  outputInfo: dict<any>,
  config: dict<any>
): void
  # Get view options before working in the view buffer.
  var autoFormatResponse = GetOpt('vrc_auto_format_response_enabled', 1)
  var syntaxHighlightResponse = GetOpt('vrc_syntax_highlight_response', 1)
  var includeResponseHeader = get(config, 'hasResponseHeader', false)
  var contentType = '' .. GetOpt('vrc_response_default_content_type', '')

  # Setup the view.
  var origWin = winnr()
  var outputWin = bufwinnr(bufnr(tmpBufName))
  if outputWin == -1
    var cmdSplit = 'vsplit'
    if GetOpt('vrc_horizontal_split', 0)
      cmdSplit = 'split'
    endif
    if GetOpt('vrc_keepalt', 0)
      cmdSplit = 'keepalt ' .. cmdSplit
    endif

    # Create the view if it is not loaded or hidden.
    execute 'rightbelow ' .. cmdSplit .. ' ' .. tmpBufName
    setlocal buftype=nofile
    outputWin = winnr()
  else
    # The view is already shown; switch to it.
    execute ':' .. outputWin .. 'wincmd w'
  endif

  # Display output in the view.
  setlocal modifiable
  silent! normal! ggdG
  var output = join(outputInfo['outputChunks'], "\n\n")
  setline(
    '.',
    split(substitute(output, '[[:return:]]', '', 'g'), '\v\n')
  )

  # Display commands in the quickfix window if any.
  if GetOpt('vrc_show_command_in_quickfix', 1)
    var commands: list<string> = outputInfo['commands']
    if !empty(commands)
      execute 'cgetexpr ' .. string(commands)
      copen
      execute ':' .. outputWin .. 'wincmd w'
    endif
  endif

  # Detect content-type based on the returned header.
  var emptyLineNum = 0
  if includeResponseHeader
    cursor(1, 0)
    emptyLineNum = search('\v^\s*$', 'n')
    var contentTypeLineNum = search(
      '\v\c^Content-Type:',
      'n',
      emptyLineNum
    )

    if contentTypeLineNum > 0
      contentType = substitute(
        getline(contentTypeLineNum),
        '\v\c^Content-Type:\s*([^;[:blank:]]*).*$',
        '\1',
        'g'
      )
    endif
  endif

  # Continue with options depending on content-type.
  if !empty(contentType)
    var fileType = substitute(
      contentType,
      '\v^.*/(.*\+)?(.*)$',
      '\2',
      'g'
    )

    # Never pass a server-controlled string to :execute unsanitized.
    if fileType !~# '^[A-Za-z0-9_+-]\+$'
      fileType = ''
    endif

    if !empty(fileType)
      # Auto-format the response.
      if autoFormatResponse
        var formatCmd = GetDict(
          'vrc_auto_format_response_patterns',
          fileType,
          autoFormatResponsePatterns
        )
        if !empty(formatCmd)
          # Auto-format the response body.
          var formattedBody = system(
            formatCmd,
            getline(emptyLineNum, '$')
          )
          if v:shell_error == 0
            silent! execute ':' .. (emptyLineNum + 1) .. ',$delete _'
            if GetOpt('vrc_auto_format_uhex', 0)
              formattedBody = substitute(
                formattedBody,
                '\v\\u(\x{4})',
                '\=nr2char(str2nr(submatch(1), 16), true)',
                'g'
              )
            endif
            append('$', split(formattedBody, '\v\n'))
          elseif GetOpt('vrc_debug', 0)
            echom 'VRC: auto-format error: ' .. v:shell_error
            echom formattedBody
          endif
        endif
      endif

      # Syntax-highlight the response.
      if syntaxHighlightResponse
        syntax clear
        try
          execute 'syntax include @vrc_' .. fileType
            .. ' syntax/' .. fileType .. '.vim'
          execute 'syntax region body start=/^$/ end=/\%$/'
            .. ' contains=@vrc_' .. fileType
        catch
        endtry
      endif
    endif
  endif

  # Display commands in the result buffer if any.
  if GetOpt('vrc_show_command_in_result_buffer', 0)
    var resultCommands: list<string> = outputInfo['commands']
    if !empty(resultCommands)
      var prefixedList = mapnew(
        copy(resultCommands),
        (_, value: string): string => 'REQUEST: ' .. value .. "\t"
      )
      append(0, prefixedList)
      append(1, '')
    endif
  endif

  # Finalize the view.
  setlocal nomodifiable
  execute ':' .. origWin .. 'wincmd w'
enddef

# Run a REST request between the given lines.
export def RunQuery(startLine: number, endLine: number): void
  var globSection = ParseGlobSection()
  var outputInfo: dict<any> = {
    'outputChunks': [],
    'commands': [],
  }

  # The while loop supports multiple requests using consecutive verbs.
  var resumeFrom = startLine
  var shouldShowCommand = GetOpt('vrc_show_command', 0)
  var shouldDebug = GetOpt('vrc_debug', 0)
  var curlOpts: dict<any> = {}
  var executed = false
  while resumeFrom <= endLine
    var request = ParseRequest(startLine, resumeFrom, endLine, globSection)
    if !request.success
      # A trailing comment-only line must not turn into an error after a
      # successful request.
      if !executed
        echom request.msg
      endif
      break
    endif
    executed = true

    var cmdAndOpts = GetCurlCommand(request)
    var curlCmd: string = cmdAndOpts[0]
    curlOpts = cmdAndOpts[1]
    if shouldDebug
      echom '[Debug] Command: ' .. curlCmd
      echom '[Debug] cUrl options: ' .. string(curlOpts)
    endif
    redraw!

    var output = CommandRunner(curlCmd .. request.pipe)
    add(outputInfo['outputChunks'], output)

    if shouldShowCommand
      add(outputInfo['commands'], curlCmd)
    endif

    if ProcessResponseHandlers(
      startLine,
      resumeFrom,
      endLine,
      output,
      outputInfo
    ) != 0
      break
    endif
    globSection = ParseGlobSection()

    resumeFrom = request.resumeFrom
  endwhile

  var outputBufferName = '' .. GetOpt(
    'vrc_output_buffer_name',
    '__REST_response__'
  )
  DisplayOutput(
    outputBufferName,
    outputInfo,
    {
      'hasResponseHeader': opt.DictHasKeys(curlOpts, ['-i', '--include']),
    }
  )
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
  var verbParts = ParseVerbQuery(resumeFrom, endLine)
  var currVerb: number = verbParts[0]
  var nextParts = ParseVerbQuery(currVerb + 1, endLine)
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
    var output = system(cmd[1], input)
    var code = v:shell_error
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
    var input = getbufline(outputBuffer, 1, '$')
    if empty(input)
      continue
    endif
    var output = system(cmd[1], input)
    var code = v:shell_error
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

# Install a command runner.  This is used by tests and will be used by the
# async/job backend in a later phase.
export def SetCommandRunner(Runner: func(string): string): void
  CommandRunner = Runner
enddef
