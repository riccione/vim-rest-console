vim9script

# Cross-platform process execution for VRC.
#
# The main curl request is started with job_start() and an argv list, so no
# shell is involved.  Shell() is reserved for user-authored shell features
# such as pipes and response handlers.

def DefaultRun(
  argv: list<string>,
  input: string,
  timeoutMs: number
): dict<any>
  var outFile = tempname()
  var errFile = tempname()
  var timedOut = false

  var job = job_start(argv, {
    'in_io': 'pipe',
    'out_io': 'file',
    'out_name': outFile,
    'err_io': 'file',
    'err_name': errFile,
  })

  if job_status(job) == 'fail'
    if filereadable(outFile)
      delete(outFile)
    endif
    if filereadable(errFile)
      delete(errFile)
    endif
    return {
      'code': -1,
      'out': '',
      'err': 'Failed to start: ' .. string(argv),
      'timedout': false,
    }
  endif

  var channel = job_getchannel(job)
  if !empty(input)
    ch_sendraw(channel, input)
  endif
  ch_close_in(channel)

  var start = reltime()
  while job_status(job) == 'run'
    sleep 10m
    if timeoutMs > 0
      && reltimefloat(reltime(start)) * 1000 >= timeoutMs
      job_stop(job, has('win32') ? 'term' : 'kill')
      timedOut = true
      break
    endif
  endwhile

  # Give a stopped job a moment to flush and close its output files.
  if timedOut
    var stopStart = reltime()
    while job_status(job) == 'run'
      && reltimefloat(reltime(stopStart)) < 2.0
      sleep 10m
    endwhile
  endif

  var info = job_info(job)
  var code = get(info, 'exitval', -1)
  var out = filereadable(outFile) ? readfile(outFile) : []
  var err = filereadable(errFile) ? readfile(errFile) : []
  if filereadable(outFile)
    delete(outFile)
  endif
  if filereadable(errFile)
    delete(errFile)
  endif

  return {
    'code': code,
    'out': substitute(join(out, "\n"), '\r\n', "\n", 'g'),
    'err': substitute(join(err, "\n"), '\r\n', "\n", 'g'),
    'timedout': timedOut,
  }
enddef

var Runner: func(list<string>, string, number): dict<any> = DefaultRun

# Replace the runner used by Run().  Intended for tests.
export def SetRunner(R: func(list<string>, string, number): dict<any>): void
  Runner = R
enddef

# Run a program without a shell and return its output and exit status.
export def Run(
  argv: list<string>,
  input: string = '',
  timeoutMs: number = 0
): dict<any>
  return Runner(argv, input, timeoutMs)
enddef

def DefaultShell(cmd: string, input: string): dict<any>
  var output = system(cmd, input)
  return {
    'code': v:shell_error,
    'out': output,
    'err': '',
    'timedout': false,
  }
enddef

var ShellRunner: func(string, string): dict<any> = DefaultShell

# Replace the shell runner used by Shell().  Intended for tests.
export def SetShellRunner(R: func(string, string): dict<any>): void
  ShellRunner = R
enddef

# Run a user-provided shell command.  This is used for pipes, response
# handlers, and body preprocessors.
export def Shell(cmd: string, input: string = ''): dict<any>
  return ShellRunner(cmd, input)
enddef

# Render an argv list for display in the quickfix list or output buffer.
export def CommandString(argv: list<string>): string
  return join(
    mapnew(argv, (_, value: string): string => shellescape(value, 1)),
    ' '
  )
enddef

# Parse a timeout value ("500ms", "30s", "1m", "1h", or plain seconds).
export def ParseTimeout(value: any): number
  var text = tolower(trim('' .. value))
  if empty(text) || text == '0'
    return 0
  endif

  var matches = matchlist(text, '\v^(\d+)(ms|s|m|h)?$')
  if empty(matches)
    return 60000
  endif

  var amount = str2nr(matches[1])
  var unit = matches[2]
  if unit == 'ms'
    return amount
  elseif unit == 'm'
    return amount * 60000
  elseif unit == 'h'
    return amount * 3600000
  endif
  # Plain numbers and the "s" suffix are seconds.
  return amount * 1000
enddef
