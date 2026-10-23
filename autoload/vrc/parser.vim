vim9script

# Request parsing for VRC.
#
# Parsing is line-oriented and does not move the cursor.  Callers that need to
# execute requests use NewState()/NextRequest(); the remaining functions are
# available for tests and for global-section parsing.

const commentDelim = '\c\v^\s*(#|//)'
const hostPattern = '\c\v^\s*HTTPS?://'
const verbPattern = '\c\v^(GET|POST|PUT|DELETE|HEAD|PATCH|OPTIONS|TRACE)\s+'

# Return the line number of the first global-section delimiter, or 0.
export def GlobSectionEnd(lines: list<string>): number
  for index in range(0, len(lines) - 1)
    if lines[index] =~# '\v^--\s*$'
      return index + 1
    endif
  endfor
  return 0
enddef

# Find the first host line in [startLine, endLine], or 0.
export def FindHostLine(
  lines: list<string>,
  startLine: number,
  endLine: number
): number
  if endLine < startLine
    return 0
  endif
  for lnum in range(startLine, endLine)
    if lines[lnum - 1] =~# hostPattern
      return lnum
    endif
  endfor
  return 0
enddef

# Find the first verb line in [startLine, endLine], or 0.
export def FindVerbLine(
  lines: list<string>,
  startLine: number,
  endLine: number
): number
  if endLine < startLine
    return 0
  endif
  for lnum in range(startLine, endLine)
    if lines[lnum - 1] =~# verbPattern
      return lnum
    endif
  endfor
  return 0
enddef

# Return true when the line looks like a request-block start.
def IsBlockCandidate(line: string): bool
  return line =~? '^HTTPS\?://' || line =~? '^--\s*$'
enddef

# Return true when a verb occurs before the next candidate block start.
def HasVerbBeforeCandidate(lines: list<string>, index: number): bool
  var next = index + 1
  while next < len(lines)
    if IsBlockCandidate(lines[next])
      return false
    endif
    if lines[next] =~# verbPattern
      return true
    endif
    next += 1
  endwhile
  return false
enddef

# Return the [start, end] line numbers of every request block.
export def BlockRanges(lines: list<string>): list<list<number>>
  var ranges: list<list<number>> = []
  var globEnd = GlobSectionEnd(lines)
  var starts: list<number> = []

  var index = globEnd == 0 ? 0 : globEnd
  while index < len(lines)
    if IsBlockCandidate(lines[index])
      && HasVerbBeforeCandidate(lines, index)
      add(starts, index + 1)
      # Skip ahead to the next possible block start.
      index += 1
      while index < len(lines) && !IsBlockCandidate(lines[index])
        index += 1
      endwhile
      continue
    endif
    index += 1
  endwhile

  if empty(starts)
    return ranges
  endif

  for i in range(0, len(starts) - 1)
    var startLine = starts[i]
    var endLine = i + 1 < len(starts) ? starts[i + 1] - 1 : len(lines)
    add(ranges, [startLine, endLine])
  endfor
  return ranges
enddef

# Find the request block containing the given line, or [0, 0].
export def FindBlock(lines: list<string>, cursorLine: number): list<number>
  for range in BlockRanges(lines)
    if cursorLine >= range[0] && cursorLine <= range[1]
      return range
    endif
  endfor
  return [0, 0]
enddef

# Split a verb line into [verb, requested-path].
export def ParseVerbLine(line: string): list<string>
  var matches = matchlist(line, verbPattern .. '(.*)$')
  if empty(matches)
    return ['', '']
  endif
  return [matches[1], trim(matches[2])]
enddef

# Parse a host between the given line numbers (inclusive end).
export def ParseHost(startLine: number, endLine: number): list<any>
  var lines = getline(1, '$')
  var lineNum = FindHostLine(lines, startLine, endLine)
  if lineNum == 0
    return [0, '']
  endif
  return [lineNum, trim(getline(lineNum))]
enddef

# Parse the query.
export def ParseVerbQuery(startLine: number, endLine: number): list<any>
  var lines = getline(1, '$')
  var lineNum = FindVerbLine(lines, startLine, endLine)
  if lineNum == 0
    return [0, '']
  endif
  return [lineNum, trim(getline(lineNum))]
enddef

# Parse a pipe command.
export def ParsePipe(startLine: number, endLine: number): string
  var pipe = ''
  if endLine < startLine
    return ''
  endif

  for line in getline(startLine, endLine)
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
  var contentTypeOpt = get(b:, 'vrc_header_content_type', get(
    g:,
    'vrc_header_content_type',
    'application/json'
  ))
  var headers: dict<any> = {'content-type': contentTypeOpt}
  if endLine < startLine
    return headers
  endif

  for line in getline(startLine, endLine)
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

  for line in getline(startLine, endLine)
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
    'curlOpts': [],
    'vals': {},
    'pipe': '',
  }

  var lines = getline(1, '$')
  var lastLine = GlobSectionEnd(lines)
  if lastLine == 0
    return globSection
  endif

  var hostLine = FindHostLine(lines, 1, lastLine - 1)
  var host = hostLine == 0 ? '' : trim(getline(hostLine))
  var parseFrom = hostLine == 0 ? 1 : hostLine + 1

  return {
    'host': host,
    'headers': ParseHeaders(parseFrom, lastLine - 1),
    'curlOpts': ParseCurlOpts(parseFrom, lastLine - 1),
    'vals': ParseVals(parseFrom, lastLine - 1),
    'pipe': ParsePipe(parseFrom, lastLine - 1),
  }
enddef

# Tokenize one option line.  Supports simple shell-style single/double quotes
# and backslash escaping without treating Windows path separators as escapes.
export def TokenizeOptionLine(line: string): list<string>
  var tokens: list<string> = []
  var current = ''
  var started = false
  var quote = ''
  var i = 0

  while i < len(line)
    var ch = line[i]
    if quote != ''
      if ch == quote
        quote = ''
        started = true
      elseif ch == '\' && quote == '"' && i + 1 < len(line)
        var next = line[i + 1]
        if next == '"' || next == '\'
          current ..= next
          i += 1
        else
          current ..= ch
        endif
      else
        current ..= ch
      endif
    elseif ch == '"' || ch == "'"
      quote = ch
      started = true
    elseif ch == '\' && i + 1 < len(line)
      var next = line[i + 1]
      if next =~ '\s' || next == '"' || next == "'" || next == '\'
        current ..= next
        i += 1
      else
        current ..= ch
      endif
      started = true
    elseif ch =~ '\s'
      if started
        add(tokens, current)
        current = ''
        started = false
      endif
    else
      current ..= ch
      started = true
    endif
    i += 1
  endwhile

  if started
    add(tokens, current)
  endif
  return tokens
enddef

# Parse the specified cUrl options into ordered {name, values} pairs.
export def ParseCurlOpts(fromLine: number, toLine: number): list<dict<any>>
  var curlOpts: list<dict<any>> = []
  for line in getline(fromLine, toLine)
    var trimmed = trim(line)
    if trimmed !~? '\v^--?\w+'
      continue
    endif
    var parts = TokenizeOptionLine(trimmed)
    if empty(parts)
      continue
    endif
    add(curlOpts, {
      'name': parts[0],
      'values': len(parts) > 1 ? parts[1 :] : [],
    })
  endfor
  return curlOpts
enddef

# Return the values of the first option with the given name.
export def OptionValues(opts: list<dict<any>>, name: string): list<string>
  for opt in opts
    if opt.name ==# name
      return opt.values
    endif
  endfor
  return []
enddef

# Return true when one of the given option names exists.
export def HasOption(opts: list<dict<any>>, names: list<string>): bool
  for opt in opts
    if index(names, opt.name) >= 0
      return true
    endif
  endfor
  return false
enddef

# Append values to an option, creating it when necessary.
export def AppendOption(
  opts: list<dict<any>>,
  name: string,
  values: list<string>
): void
  for opt in opts
    if opt.name ==# name
      extend(opt.values, values)
      return
    endif
  endfor
  add(opts, {'name': name, 'values': copy(values)})
enddef

# Merge two option lists.  Options in override replace same-named options in
# base; repeated options inside either list are preserved.
export def MergeCurlOpts(
  base: list<dict<any>>,
  override: list<dict<any>>
): list<dict<any>>
  var overrideNames: list<string> = []
  for opt in override
    add(overrideNames, opt.name)
  endfor

  var merged: list<dict<any>> = []
  for opt in base
    if index(overrideNames, opt.name) < 0
      add(merged, deepcopy(opt))
    endif
  endfor
  extend(merged, deepcopy(override))
  return merged
enddef

# Flatten ordered options into command-line arguments.
export def PairsToArgs(opts: list<dict<any>>): list<string>
  var args: list<string> = []
  for opt in opts
    if empty(opt.values)
      add(args, opt.name)
      continue
    endif
    for value in opt.values
      extend(args, [opt.name, value])
    endfor
  endfor
  return args
enddef

# Create a parser state for a request block.
export def NewState(
  startLine: number,
  endLine: number,
  globSection: dict<any>
): dict<any>
  return {
    'startLine': startLine,
    'endLine': endLine,
    'pos': startLine,
    'glob': globSection,
  }
enddef

# Parse the next request in the block.
export def NextRequest(state: dict<any>): dict<any>
  var lines = getline(1, '$')
  var startLine: number = state.startLine
  var endLine: number = state.endLine
  var pos: number = state.pos
  var globSection: dict<any> = state.glob

  if pos > endLine
    return {
      'success': false,
      'msg': 'Missing query',
    }
  endif

  var firstVerb = FindVerbLine(lines, startLine, endLine)
  if firstVerb == 0
    return {
      'success': false,
      'msg': 'Missing query',
    }
  endif

  var hostLine = FindHostLine(lines, startLine, firstVerb - 1)
  var host = ''
  if hostLine == 0
    host = get(globSection, 'host', '')
    hostLine = startLine
  else
    host = trim(lines[hostLine - 1])
  endif
  if empty(host)
    return {
      'success': false,
      'msg': 'Missing host',
    }
  endif

  var verbLine = FindVerbLine(lines, pos, endLine)
  if verbLine == 0
    return {
      'success': false,
      'msg': 'Missing query',
    }
  endif

  var nextVerb = FindVerbLine(lines, verbLine + 1, endLine)
  var nextResumeFrom = nextVerb == 0 ? endLine + 1 : nextVerb

  # Block-level headers, options, and pipe are only read before the first
  # verb.  This prevents request bodies from being interpreted as headers.
  var localHeaders = ParseHeaders(hostLine + 1, firstVerb - 1)
  var headers: dict<any> = deepcopy(get(globSection, 'headers', {}))
  extend(headers, localHeaders)

  var localCurlOpts = ParseCurlOpts(hostLine + 1, firstVerb - 1)
  var curlOpts = MergeCurlOpts(
    get(globSection, 'curlOpts', []),
    localCurlOpts
  )

  var pipe = ParsePipe(hostLine + 1, firstVerb - 1)
  if pipe == ''
    pipe = get(globSection, 'pipe', '')
  endif

  var vals: dict<any> = get(globSection, 'vals', {})
  var verbPath = ParseVerbLine(lines[verbLine - 1])
  var httpVerb = verbPath[0]
  var queryPath = verbPath[1]
  var dataBody = getline(verbLine + 1, nextVerb == 0 ? endLine : nextVerb - 1)

  queryPath = SubstituteVars(queryPath, vals)
  dataBody = mapnew(
    dataBody,
    (_, value: string): string => SubstituteVars(value, vals)
  )
  headers = mapnew(
    headers,
    (_, value: string): string => SubstituteVars(value, vals)
  )
  dataBody = filter(
    dataBody,
    (_, value: string): bool =>
      value !~? '\v^\s*(#|//).*$|\v^\s*$'
  )

  state.pos = nextResumeFrom

  return {
    'success': true,
    'resumeFrom': nextResumeFrom,
    'lineNum': verbLine,
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
