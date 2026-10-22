vim9script

# Phase 1 regression tests.  Run with:
#   vim -Nu NONE -n -es -S test/run.vim

var root = expand('<sfile>:p:h:h')
execute 'set rtp^=' .. fnameescape(root)
filetype plugin on
runtime! plugin/vrc.vim

import autoload 'vrc.vim' as vrc
import autoload 'vrc/opt.vim' as opt
import autoload 'vrc/parser.vim' as parser
import autoload 'vrc/exec.vim' as exec

var results: list<string> = []
var failures = 0

def Check(name: string, expected: any, actual: any): void
  if expected == actual
    add(results, 'ok   ' .. name)
  else
    failures += 1
    add(
      results,
      'FAIL ' .. name .. ': expected ' .. string(expected)
        .. ', got ' .. string(actual)
    )
  endif
enddef

def CheckTrue(name: string, value: bool): void
  Check(name, true, value)
enddef

def ResetBuffer(lines: list<string>): void
  enew!
  if !empty(lines)
    setline(1, lines)
  endif
enddef

def TestHeaderParsing(): void
  ResetBuffer([
    'http://host',
    'Authorization:Bearer token',
    'X-Time: 12:34',
    'Content-Type:application/json',
  ])
  var headers = parser.ParseHeaders(1, 4)
  Check('header without space after colon', 'Bearer token',
    headers['authorization'])
  Check('header value containing colon', '12:34', headers['x-time'])
  Check('content-type header overrides default', 'application/json',
    headers['content-type'])
enddef

def TestSubstituteVars(): void
  Check(
    'variable values are literal and longest key wins',
    '/x & y/Z',
    parser.SubstituteVars('/:a/:ab', {'a': 'x & y', 'ab': 'Z'})
  )
  Check(
    'backslashes in variable values are literal',
    'C:\tmp\x',
    parser.SubstituteVars(':path', {'path': 'C:\tmp\x'})
  )
  Check(
    'replacement expressions are not evaluated',
    '\=1+1',
    parser.SubstituteVars(':value', {'value': '\=1+1'})
  )
enddef

def TestGlobalSection(): void
  ResetBuffer([
    'http://host',
    'Accept: application/json',
    '-L',
    '--connect-timeout 10',
    '| jq .',
    'city = Some%20City',
    '--',
    '',
    '--',
    'GET /city/:city',
  ])
  var glob = parser.ParseGlobSection()
  Check('global host is parsed', 'http://host', glob['host'])
  Check('global header is parsed', 'application/json',
    glob['headers']['accept'])
  Check('global curl flag is parsed', [],
    parser.OptionValues(glob['curlOpts'], '-L'))
  Check('global curl value is parsed', ['10'],
    parser.OptionValues(glob['curlOpts'], '--connect-timeout'))
  Check('global pipe is parsed', '| jq .', glob['pipe'])
  Check('global variable is parsed', 'Some%20City', glob['vals']['city'])
enddef

def TestQueryPathAndBlocks(): void
  ResetBuffer(['GET /x a=1 b=2'])
  var glob: dict<any> = {
    'host': 'http://h',
    'headers': {},
    'curlOpts': [],
    'vals': {},
    'pipe': '',
  }
  var state = parser.NewState(1, 1, glob)
  var request = parser.NextRequest(state)
  Check('query path preserves spaces after the verb', '/x a=1 b=2',
    request.requestPath)

  ResetBuffer(['http://global', '--', 'POST /x', 'http://evil'])
  glob = {
    'host': 'http://global',
    'headers': {},
    'curlOpts': [],
    'vals': {},
    'pipe': '',
  }
  state = parser.NewState(2, 4, glob)
  request = parser.NextRequest(state)
  Check('body URL does not replace the host', 'http://global', request.host)

  ResetBuffer([
    'http://global',
    '--',
    '',
    'http://one',
    'GET /1',
    '',
    'http://two',
    'GET /2',
  ])
  var lines = getline(1, '$')
  Check('blocks are found structurally', [[4, 6], [7, 8]],
    parser.BlockRanges(lines))
  Check('cursor line finds its block', [4, 6],
    parser.FindBlock(lines, 5))
  Check('lines between blocks are not executed', [0, 0],
    parser.FindBlock(lines, 3))

  ResetBuffer(['http://h', 'GET /', 'http://evil'])
  Check('body URL without a following verb is not a block', [[1, 3]],
    parser.BlockRanges(getline(1, '$')))
enddef

def HasArg(argv: list<string>, name: string, value: string): bool
  if len(argv) < 2
    return false
  endif
  for i in range(0, len(argv) - 2)
    if argv[i] ==# name && argv[i + 1] ==# value
      return true
    endif
  endfor
  return false
enddef

def TestOptionParsing(): void
  Check(
    'option tokenizer keeps quoted values together',
    ['-H', 'X: y'],
    parser.TokenizeOptionLine('-H "X: y"')
  )
  Check(
    'option tokenizer handles single quotes',
    ['--data', '{"a":1}'],
    parser.TokenizeOptionLine("--data '{\"a\":1}'")
  )
  Check(
    'option tokenizer preserves Windows paths',
    ['--data-binary', '@C:\tmp\x'],
    parser.TokenizeOptionLine('--data-binary @C:\tmp\x')
  )

  ResetBuffer(['-H "X: y"', '--data ''{"a":1}'''])
  Check(
    'curl options keep file order and values',
    [
      {'name': '-H', 'values': ['X: y']},
      {'name': '--data', 'values': ['{"a":1}']},
    ],
    parser.ParseCurlOpts(1, 2)
  )
enddef

def TestBuildRequest(): void
  ResetBuffer(['http://h', '-H "X: y"', 'GET /x a=1'])
  var glob = parser.ParseGlobSection()
  var state = parser.NewState(1, 3, glob)
  var request = parser.NextRequest(state)
  var built = vrc.BuildRequest(request)

  Check('curl is invoked directly', 'curl', built.argv[0])
  Check('custom header is one argument', true,
    HasArg(built.argv, '-H', 'X: y'))
  Check('default content type is added', true,
    HasArg(built.argv, '-H', 'content-type: application/json'))
  Check('progress meter is suppressed', true,
    index(built.argv, '-sS') >= 0)
  Check('external timeout is not used', false,
    index(built.argv, 'timeout') >= 0)
  Check('URL keeps the text after the verb', 'http://h/x a=1',
    built.argv[-1])

  ResetBuffer(['http://h', 'POST /x', '{"a":1}'])
  glob = parser.ParseGlobSection()
  state = parser.NewState(1, 3, glob)
  request = parser.NextRequest(state)
  built = vrc.BuildRequest(request)
  Check('inline body is sent through stdin', '{"a":1}', built.input)
  Check('inline body uses @-', true,
    HasArg(built.argv, '--data-binary', '@-'))

  ResetBuffer(['http://h', 'DELETE /x', 'q=1'])
  glob = parser.ParseGlobSection()
  state = parser.NewState(1, 3, glob)
  request = parser.NextRequest(state)
  built = vrc.BuildRequest(request)
  Check('DELETE data uses query parameters', true,
    index(built.argv, '-G') >= 0)
  Check('DELETE data is URL-encoded', true,
    HasArg(built.argv, '--data-urlencode', 'q=1'))

  var bodyFile = tempname()
  writefile(['from file'], bodyFile)
  ResetBuffer(['http://h', 'POST /x', '@' .. bodyFile])
  glob = parser.ParseGlobSection()
  state = parser.NewState(1, 3, glob)
  request = parser.NextRequest(state)
  built = vrc.BuildRequest(request)
  Check('file body resolves to an absolute path', true,
    HasArg(built.argv, '--data-binary', '@' .. bodyFile))
  Check('file body does not use stdin', '', built.input)
  delete(bodyFile)
enddef

def TestExecDefaults(): void
  var argv = has('win32')
    ? ['cmd', '/c', 'echo hello']
    : ['/bin/echo', 'hello']
  var result = exec.Run(argv)
  Check('job_start runs an argv list', 'hello', trim(result.out))
  Check('exit status is captured', 0, result.code)

  if has('unix')
    var failed = exec.Run(['/bin/sh', '-c', 'echo err >&2; exit 3'])
    Check('stderr is captured', 'err', trim(failed.err))
    Check('non-zero exit status is captured', 3, failed.code)

    var timedOut = exec.Run(['/bin/sleep', '2'], '', 100)
    Check('timeout stops the job', true, timedOut.timedout)
  endif

  Check('minutes parse to milliseconds', 60000, exec.ParseTimeout('1m'))
  Check('seconds parse to milliseconds', 30000, exec.ParseTimeout('30s'))
  Check('milliseconds are preserved', 500, exec.ParseTimeout('500ms'))
  Check('zero disables the timeout', 0, exec.ParseTimeout('0'))
enddef

def TestRunnerInput(): void
  var inputs: list<string> = []
  def Runner(argv: list<string>, input: string, timeoutMs: number): dict<any>
    add(inputs, input)
    return {'code': 0, 'out': 'response', 'err': '', 'timedout': false}
  enddef
  exec.SetRunner(Runner)

  ResetBuffer(['http://h', 'POST /x', '{"a":1}'])
  g:vrc_output_buffer_name = '__VRC_TEST_OUT__'
  g:vrc_auto_format_response_enabled = 0
  g:vrc_syntax_highlight_response = 0
  vrc.RunQuery(1, 3)
  Check('RunQuery passes the inline body to the runner', '{"a":1}',
    inputs[0])
  unlet g:vrc_auto_format_response_enabled
  unlet g:vrc_syntax_highlight_response
enddef

def TestPipeRunner(): void
  var shellInputs: list<string> = []
  def ShellRunner(cmd: string, input: string): dict<any>
    add(shellInputs, input)
    return {'code': 0, 'out': 'PIPED', 'err': '', 'timedout': false}
  enddef
  exec.SetShellRunner(ShellRunner)

  var curlCalls: list<list<string>> = []
  def Runner(argv: list<string>, input: string, timeoutMs: number): dict<any>
    add(curlCalls, argv)
    return {'code': 0, 'out': 'RAW', 'err': '', 'timedout': false}
  enddef
  exec.SetRunner(Runner)

  g:vrc_output_buffer_name = '__VRC_TEST_OUT__'
  g:vrc_auto_format_response_enabled = 0
  g:vrc_syntax_highlight_response = 0
  ResetBuffer(['http://h', '| tr a-z A-Z', 'GET /'])
  vrc.RunQuery(1, 3)
  Check('pipe receives curl output', 'RAW', shellInputs[0])
  Check('pipe output replaces the response', 'PIPED',
    getbufline(bufnr('__VRC_TEST_OUT__'), 1)[0])
  unlet g:vrc_auto_format_response_enabled
  unlet g:vrc_syntax_highlight_response
enddef

def TestOptions(): void
  if has_key(g:, 'vrc_curl_opts')
    unlet g:vrc_curl_opts
  endif
  if has_key(b:, 'vrc_curl_opts')
    unlet b:vrc_curl_opts
  endif

  g:vrc_curl_opts = {'-H': ['A: b']}
  var first = opt.GetDefaultCurlOpts()
  add(first['-H'], 'x: y')
  var second = opt.GetDefaultCurlOpts()
  Check('global curl options are deep-copied', ['A: b'],
    g:vrc_curl_opts['-H'])
  Check('later reads start from the configured list', ['A: b'],
    second['-H'])

  b:vrc_curl_opts = {'-L': ''}
  Check('buffer-local curl options take precedence', '',
    opt.GetDefaultCurlOpts()['-L'])

  unlet b:vrc_curl_opts
  Check(
    'numeric zero and empty lists are handled correctly',
    ['--max-time', '0', '-sS'],
    opt.DictToCurlArgs({'-H': [], '--max-time': 0, '-sS': ''})
  )
enddef

def TestConsecutiveVerbs(): void
  var oldOutputName = get(g:, 'vrc_output_buffer_name', '__REST_response__')
  g:vrc_output_buffer_name = '__VRC_TEST_OUT__'
  g:vrc_auto_format_response_enabled = 0
  g:vrc_syntax_highlight_response = 0

  var calls: list<list<string>> = []
  def Runner(argv: list<string>, input: string, timeoutMs: number): dict<any>
    add(calls, argv)
    return {'code': 0, 'out': 'response', 'err': '', 'timedout': false}
  enddef
  exec.SetRunner(Runner)

  ResetBuffer(['http://h', 'GET /1', 'GET /2'])
  vrc.RunQuery(1, 3)
  Check('all consecutive verbs are executed', 2, len(calls))

  calls = []
  ResetBuffer(['http://h'])
  vrc.RunQuery(1, 1)
  Check('host-only block does not execute a request', 0, len(calls))

  g:vrc_output_buffer_name = oldOutputName
  unlet g:vrc_auto_format_response_enabled
  unlet g:vrc_syntax_highlight_response
enddef

def TestQueryEntryPoint(): void
  var oldOutputName = get(g:, 'vrc_output_buffer_name', '__REST_response__')
  g:vrc_output_buffer_name = '__VRC_TEST_OUT__'
  g:vrc_auto_format_response_enabled = 0
  g:vrc_syntax_highlight_response = 0

  var calls: list<list<string>> = []
  def Runner(argv: list<string>, input: string, timeoutMs: number): dict<any>
    add(calls, argv)
    return {'code': 0, 'out': 'response', 'err': '', 'timedout': false}
  enddef
  exec.SetRunner(Runner)

  ResetBuffer(['http://h', 'GET /1', 'GET /2'])
  setlocal filetype=rest
  cursor(2, 1)
  g:VrcQuery()
  Check('query entry point runs the final verb', 2, len(calls))

  calls = []
  cursor(2, 1)
  execute 'VrcQuery'
  Check('VrcQuery command runs the final verb', 2, len(calls))

  g:vrc_output_buffer_name = oldOutputName
  unlet g:vrc_auto_format_response_enabled
  unlet g:vrc_syntax_highlight_response
enddef

def TestTraceHandler(): void
  ResetBuffer(['GET /', '#> <<echo hi'])
  if has_key(g:, 'vrc_show_command')
    unlet g:vrc_show_command
  endif
  var info: dict<any> = {'outputChunks': [], 'commands': []}
  vrc.ProcessResponseHandlers(1, 1, 2, '', info)
  Check('trace handler writes to quickfix without vrc_show_command', 1,
    len(info['commands']))
  if !empty(info['commands'])
    Check('trace handler output is preserved', 'hi',
      trim(info['commands'][0]))
  endif
enddef

TestHeaderParsing()
TestSubstituteVars()
TestGlobalSection()
TestQueryPathAndBlocks()
TestOptionParsing()
TestBuildRequest()
TestExecDefaults()
TestOptions()
TestConsecutiveVerbs()
TestQueryEntryPoint()
TestRunnerInput()
TestTraceHandler()
TestPipeRunner()

results->add('')
if failures > 0
  results->add('FAILED: ' .. failures .. ' test(s)')
else
  results->add('PASSED: ' .. len(results) .. ' checks')
endif

if has('win32')
  for line in results
    echomsg line
  endfor
else
  writefile(results, '/dev/stdout')
endif

if failures > 0
  cquit
endif
qa!
