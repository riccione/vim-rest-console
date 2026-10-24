vim9script

# Async execution tests.  Run with:
#   vim -Nu NONE -n -es -S test/async.vim

var root = expand('<sfile>:p:h:h')
execute 'set rtp^=' .. fnameescape(root)
filetype plugin on
set hidden
runtime! plugin/vrc.vim

import autoload 'vrc.vim' as vrc
import autoload 'vrc/exec.vim' as exec

var results: list<string> = []
var failures = 0

def Check(name: string, expected: any, actual: any): void
  if expected == actual
    add(results, 'ok   ' .. name)
  else
    failures += 1
    add(results, 'FAIL ' .. name .. ': expected ' .. string(expected)
      .. ', got ' .. string(actual))
  endif
enddef

def ResetBuffer(lines: list<string>): void
  enew!
  if !empty(lines)
    setline(1, lines)
  endif
enddef

def SetAsyncOptions(): void
  g:vrc_async = 1
  g:vrc_output_buffer_name = '__VRC_ASYNC_OUT__'
  g:vrc_auto_format_response_enabled = 0
  g:vrc_syntax_highlight_response = 0
  g:vrc_show_command = 0
  g:vrc_show_command_in_quickfix = 0
  g:vrc_show_command_in_result_buffer = 0
  g:vrc_curl_timeout = '5s'
enddef

def ClearAsyncOptions(): void
  unlet! g:vrc_async
  unlet! g:vrc_output_buffer_name
  unlet! g:vrc_auto_format_response_enabled
  unlet! g:vrc_syntax_highlight_response
  unlet! g:vrc_show_command
  unlet! g:vrc_show_command_in_quickfix
  unlet! g:vrc_show_command_in_result_buffer
  unlet! g:vrc_curl_timeout
enddef

var Calls: list<list<string>> = []
var Responses: list<dict<any>> = []
var Pending: list<dict<any>> = []
var Defer = false
var RealDone = false
var RealResult: dict<any> = {}

def RealOnDone(result: dict<any>): void
  RealResult = result
  RealDone = true
enddef

def Starter(
  argv: list<string>,
  input: string,
  timeoutMs: number,
  OnDone: func(dict<any>): void
): dict<any>
  add(Calls, argv)
  if Defer
    add(Pending, {'on_done': OnDone})
  elseif !empty(Responses)
    OnDone(remove(Responses, 0))
  else
    OnDone({'code': 0, 'out': '', 'err': '', 'timedout': false, 'cancelled': false})
  endif
  return {'job': v:null, 'cancel': () => 0}
enddef

def CompleteNext(result: dict<any>): void
  if empty(Pending)
    return
  endif
  var pending = remove(Pending, 0)
  pending.on_done(result)
enddef

def OutputLines(): list<string>
  var buf = bufnr('__VRC_ASYNC_OUT__')
  return buf == -1 ? [] : getbufline(buf, 1, '$')
enddef

def TestRealAsyncExec(): void
  var argv = has('win32')
    ? ['cmd', '/c', 'echo hello']
    : ['/bin/echo', 'hello']
  RealDone = false
  RealResult = {}
  exec.Start(argv, '', 0, RealOnDone)
  var start = reltime()
  while !RealDone && reltimefloat(reltime(start)) < 3.0
    sleep 10m
  endwhile
  Check('real async job completes', true, RealDone)
  Check('real async job captures output', 'hello', trim(RealResult.out))

  if has('unix')
    RealDone = false
    RealResult = {}
    exec.Start(['/bin/sleep', '2'], '', 100, RealOnDone)
    start = reltime()
    while !RealDone && reltimefloat(reltime(start)) < 3.0
      sleep 10m
    endwhile
    Check('real async timeout fires', true, RealResult.timedout)
  endif
enddef

def TestAsyncSingle(): void
  ResetBuffer(['http://h', 'GET /x'])
  SetAsyncOptions()
  Defer = false
  Calls = []
  Responses = [{'code': 0, 'out': 'body', 'err': '', 'timedout': false, 'cancelled': false}]
  vrc.StartAsyncRun(1, 2, bufnr('%'))
  Check('single async request finishes', false, vrc.IsRunning())
  Check('single async request executes curl once', 1, len(Calls))
  Check('single async request displays output', ['body'], OutputLines())
  ClearAsyncOptions()
enddef

def TestAsyncConsecutive(): void
  ResetBuffer(['http://h', 'GET /1', 'GET /2'])
  SetAsyncOptions()
  Defer = false
  Calls = []
  Responses = [
    {'code': 0, 'out': 'one', 'err': '', 'timedout': false, 'cancelled': false},
    {'code': 0, 'out': 'two', 'err': '', 'timedout': false, 'cancelled': false},
  ]
  vrc.StartAsyncRun(1, 3, bufnr('%'))
  Check('consecutive async requests finish', false, vrc.IsRunning())
  Check('consecutive async requests execute twice', 2, len(Calls))
  Check('consecutive async requests display both chunks', ['one', '', 'two'],
    OutputLines())
  ClearAsyncOptions()
enddef

def TestAsyncHandler(): void
  ResetBuffer([
    'http://h',
    'X: old',
    '--',
    '--',
    'GET /x',
    '#>X: <<handler',
  ])
  SetAsyncOptions()
  Defer = false
  Calls = []
  Responses = [
    {'code': 0, 'out': 'body', 'err': '', 'timedout': false, 'cancelled': false},
    {'code': 0, 'out': 'new', 'err': '', 'timedout': false, 'cancelled': false},
  ]
  vrc.StartAsyncRun(4, 6, bufnr('%'))
  Check('async handler updates the source buffer', 'X: new', getline(2))
  Check('async handler shell command runs', 2, len(Calls))
  ClearAsyncOptions()
enddef

def TestAsyncCancel(): void
  ResetBuffer(['http://h', 'GET /slow'])
  SetAsyncOptions()
  Defer = true
  Calls = []
  Pending = []
  vrc.StartAsyncRun(1, 2, bufnr('%'))
  Check('async run is active before cancel', true, vrc.IsRunning())
  vrc.Cancel()
  Check('cancel clears the active run', false, vrc.IsRunning())
  Check('cancel is reported in the output', true,
    index(OutputLines(), 'VRC: cancelled') >= 0)
  Pending = []
  ClearAsyncOptions()
enddef

def TestAsyncTimeout(): void
  ResetBuffer(['http://h', 'GET /slow'])
  SetAsyncOptions()
  Defer = false
  Responses = [
    {'code': -1, 'out': 'partial', 'err': '', 'timedout': true, 'cancelled': false},
  ]
  vrc.StartAsyncRun(1, 2, bufnr('%'))
  Check('timeout finishes the run', false, vrc.IsRunning())
  Check('timeout is reported in the output', true,
    index(OutputLines(), 'VRC: request timed out') >= 0)
  ClearAsyncOptions()
enddef

def TestAsyncQueue(): void
  ResetBuffer(['http://h', 'GET /1', '', 'http://h2', 'GET /2'])
  SetAsyncOptions()
  Defer = true
  Calls = []
  Pending = []
  Responses = []
  vrc.StartAsyncRun(1, 3, bufnr('%'))
  vrc.StartAsyncRun(4, 5, bufnr('%'))
  Check('second async run is queued', 1, len(Calls))
  Defer = false
  Responses = [{'code': 0, 'out': 'two', 'err': '', 'timedout': false, 'cancelled': false}]
  CompleteNext({'code': 0, 'out': 'one', 'err': '', 'timedout': false, 'cancelled': false})
  Check('queued async run executes after completion', 2, len(Calls))
  Check('queued async run finishes', false, vrc.IsRunning())
  Check('queued async output displays the latest run', ['two'], OutputLines())
  ClearAsyncOptions()
enddef

def TestAsyncRange(): void
  ResetBuffer(['http://h', 'GET /1', '', 'http://h2', 'GET /2'])
  SetAsyncOptions()
  Defer = false
  Calls = []
  Responses = [
    {'code': 0, 'out': 'one', 'err': '', 'timedout': false, 'cancelled': false},
    {'code': 0, 'out': 'two', 'err': '', 'timedout': false, 'cancelled': false},
  ]
  vrc.Query(1, 5)
  Check('async range executes both blocks', 2, len(Calls))
  Check('async range displays both chunks', ['one', '', 'two'], OutputLines())
  ClearAsyncOptions()
enddef

def TestAsyncBufferSwitch(): void
  ResetBuffer([
    'http://h',
    'X: old',
    '--',
    '--',
    'GET /x',
    '#>X: <<handler',
  ])
  var sourceBuf = bufnr('%')
  SetAsyncOptions()
  Defer = true
  Calls = []
  Pending = []
  Responses = []
  vrc.StartAsyncRun(4, 6, sourceBuf)

  enew!
  setline(1, ['other buffer'])
  Defer = false
  Responses = [{'code': 0, 'out': 'new', 'err': '', 'timedout': false, 'cancelled': false}]
  CompleteNext({'code': 0, 'out': 'body', 'err': '', 'timedout': false, 'cancelled': false})
  Check('async handler targets the source buffer after a buffer switch',
    'X: new', getbufline(sourceBuf, 2)[0])
  ClearAsyncOptions()
enddef

TestRealAsyncExec()
exec.SetJobStarter(Starter)
TestAsyncSingle()
TestAsyncConsecutive()
TestAsyncHandler()
TestAsyncCancel()
TestAsyncTimeout()
TestAsyncQueue()
TestAsyncRange()
TestAsyncBufferSwitch()

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
