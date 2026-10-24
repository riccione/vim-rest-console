vim9script

# Helpers for VRC options and cURL argument construction.

# Get an option, preferring the buffer-local value over the global value.
export def Get(name: string, default: any): any
  return get(b:, name, get(g:, name, default))
enddef

# Get an option for a specific buffer.  Use -1 for the current buffer.
export def GetFor(targetBuf: number, name: string, default: any): any
  if targetBuf < 0
    return Get(name, default)
  endif
  return get(getbufvar(targetBuf, ''), name, get(g:, name, default))
enddef

# Get the default cURL options.  The buffer-local option takes precedence over
# the global option.  A deep copy is returned so callers can safely add or
# overwrite values without mutating the user's configuration.
export def GetDefaultCurlOpts(targetBuf: number = -1): dict<any>
  var bufferVars: dict<any> = targetBuf < 0 ? b: : getbufvar(targetBuf, '')
  var opts: any = {}
  if has_key(bufferVars, 'vrc_curl_opts')
    opts = bufferVars['vrc_curl_opts']
  elseif has_key(g:, 'vrc_curl_opts')
    opts = g:vrc_curl_opts
  else
    return {}
  endif

  if type(opts) != v:t_dict
    echohl ErrorMsg
    echom 'Option vrc_curl_opts should be a dictionary.'
    echohl None
    return {}
  endif

  return deepcopy(opts)
enddef

# Convert a dictionary of cURL options to ordered {name, values} pairs.
export def DictToCurlPairs(dictOpts: dict<any>): list<dict<any>>
  var pairs: list<dict<any>> = []
  for key in sort(keys(dictOpts))
    var optVal: any = dictOpts[key]
    var optType = type(optVal)
    var values: list<string> = []

    if optType == v:t_list
      if empty(optVal)
        continue
      endif
      values = mapnew(optVal, (_, value: any): string => ValueToString(value))
    elseif optType == v:t_string && empty(optVal)
      values = []
    else
      values = [ValueToString(optVal)]
    endif

    add(pairs, {'name': key, 'values': values})
  endfor
  return pairs
enddef

# Convert a dictionary of cURL options to a list of command line arguments.
#
# - An empty string or an empty list means the option is a flag.
# - Numeric values, including 0, are passed through as their string value.
# - A list value produces one option argument per list item.
export def DictToCurlArgs(dictOpts: dict<any>): list<string>
  var opts: list<string> = []
  for key in sort(keys(dictOpts))
    var optVal: any = dictOpts[key]
    var optType = type(optVal)

    if optType == v:t_list
      if empty(optVal)
        # An empty list is not a useful cURL option; skip it entirely.
        continue
      endif
      for val in optVal
        add(opts, key)
        add(opts, ValueToString(val))
      endfor
      continue
    endif

    if optType == v:t_string && empty(optVal)
      add(opts, key)
      continue
    endif

    add(opts, key)
    add(opts, ValueToString(optVal))
  endfor
  return opts
enddef

# Check if a dictionary has one of the given keys.
export def DictHasKeys(dictOpts: dict<any>, keys: list<string>): bool
  for key in keys
    if has_key(dictOpts, key)
      return true
    endif
  endfor
  return false
enddef

def ValueToString(value: any): string
  if type(value) == v:t_string
    return value
  endif
  return string(value)
enddef
