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
    glob['curlOpts']['-L'])
  Check('global curl value is parsed', ['10'],
    glob['curlOpts']['--connect-timeout'])
  Check('global pipe is parsed', '| jq .', glob['pipe'])
  Check('global variable is parsed', 'Some%20City', glob['vals']['city'])
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

  var calls: list<string> = []
  def Runner(cmd: string): string
    add(calls, cmd)
    return 'response'
  enddef
  vrc.SetCommandRunner(Runner)

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

  var calls: list<string> = []
  def Runner(cmd: string): string
    add(calls, cmd)
    return 'response'
  enddef
  vrc.SetCommandRunner(Runner)

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
TestOptions()
TestConsecutiveVerbs()
TestQueryEntryPoint()
TestTraceHandler()

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
