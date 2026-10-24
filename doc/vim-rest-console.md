<!-- Generated from doc/vim-rest-console.txt. Do not edit manually. -->

# Vim REST Console (VRC)

A plug-in to help work with RESTful services.

VRC creates a vim-friendly console to interact with RESTful services.

<a id="VrcContents"></a>
## Contents

* [1. Introduction](#VrcIntroduction)
* [2. Features](#VrcFeatures)
* [3. Installation](#VrcInstallation)
* [4. Examples](#VrcExamples)
  * [4.1 Single VRC Buffer](#VrcExSingleBuffer)
  * [4.2 Multiple VRC Buffers](#VrcExMultiBuffers)
* [5. Usage](#VrcUsage)
  * [5.1 cUrl Options](#VrcCurlOptions)
  * [5.2 Global Definitions](#VrcGlobalDefinitions)
  * [5.3 Global Variable Declaration](#VrcGlobalVarDecl)
  * [5.4 Line-by-line Request Body](#VrcSplitRequestBody)
  * [5.5 Consecutive Request Verbs](#VrcConReqVerbs)
  * [5.6 Response handlers](#VrcResponseHandlers)
  * [5.7 Asynchronous Execution](#VrcAsyncExecution)
* [6. Configuration](#VrcConfiguration)
  * [vrc_allow_get_request_body](#vrc_allow_get_request_body)
  * [vrc_async](#vrc_async)
  * [vrc_auto_format_response_enabled](#vrc_auto_format_response_enabled)
  * [vrc_auto_format_response_patterns](#vrc_auto_format_response_patterns)
  * [vrc_auto_format_uhex](#vrc_auto_format_uhex)
  * [vrc_body_preprocessor](#vrc_body_preprocessor)
  * [vrc_curl_opts](#vrc_curl_opts)
  * [vrc_curl_timeout](#vrc_curl_timeout)
  * [vrc_debug](#vrc_debug)
  * [vrc_elasticsearch_support](#vrc_elasticsearch_support)
  * [vrc_header_content_type](#vrc_header_content_type)
  * [vrc_horizontal_split](#vrc_horizontal_split)
  * [vrc_keepalt](#vrc_keepalt)
  * [vrc_output_buffer_name](#vrc_output_buffer_name)
  * [vrc_response_default_content_type](#vrc_response_default_content_type)
  * [vrc_set_default_mapping](#vrc_set_default_mapping)
  * [vrc_show_command](#vrc_show_command)
  * [vrc_show_command_in_quickfix](#vrc_show_command_in_quickfix)
  * [vrc_show_command_in_result_buffer](#vrc_show_command_in_result_buffer)
  * [vrc_split_request_body](#vrc_split_request_body)
  * [vrc_syntax_highlight_response](#vrc_syntax_highlight_response)
  * [vrc_trigger](#vrc_trigger)
* [7. Tips 'n Tricks](#VrcTnt)
  * [7.1 POST Data in Bulk](#VrcTntDataBulk)
  * [7.2 Syntax Highlighting](#VrcTntStxHi)
* [8. Contributors](#VrcContributors)
* [9. License](#VrcLicense)

<a id="VrcIntroduction"></a>

## 1. Introduction

This plug-in is to help send requests to and display responses from RESTful
services in Vim. It's useful for working with REST services that use JSON to
exchange information between server and client such as Elasticsearch.

VRC can also be used as a cURL client for simple needs such as getting a
HTTP page response or posting to a form.

Requirements:
* cURL
* Vim 9.0 or newer

<a id="VrcFeatures"></a>

## 2. Features

* Execute REST request and display the response on a separate display buffer.
* Make changing/adjusting request body easy.
* Can have multiple REST request blocks per VRC buffer.
* Can have multiple VRC buffers where they all share the same output buffer or
  each can have its own output buffer.
* Particularly useful for working with REST services that require the request
  body to be sent in JSON such as Elasticsearch.
* Syntax highlighting.
* Supported verbs: GET, POST, PUT, DELETE, HEAD, PATCH, OPTIONS, and TRACE.

<a id="VrcInstallation"></a>

## 3. Installation

To install using pathogen.vim

```sh
cd ~/.vim/bundle
git clone https://github.com/riccione/vim-rest-console.git
```

To install using Vundle

```
" Add this line to .vimrc
Plugin 'riccione/vim-rest-console'
```

Other methods should work as well.

<a id="VrcExamples"></a>

## 4. Examples

For more examples, check out

https://raw.githubusercontent.com/riccione/vim-rest-console/main/examples/sample.rest

The following examples assume that an Elasticsearch service is running at
localhost. The pipe (|) indicates the current position of the cursor.

<a id="VrcExSingleBuffer"></a>

### 4.1 Single VRC Buffer

* From the command line, run a new Vim instance.
* Set the buffer `filetype` to 'rest' by

```
:set ft=rest
```

* Type in

```http
http://localhost:9200
GET /_cat/nodes?v|
```

* Hit the trigger key (<C-j> by default).
* A new vertically split buffer will be shown to display the output.
* Change the request block to (or add another one)

```http
http://localhost:9200
POST /testindex/testtype
{
    "key": "new key",
    "value": "new value"|
}
```

* Hit the trigger key with the cursor placed anywhere within this request
    block.
* The display buffer will be updated with the new response.

<a id="VrcExMultiBuffers"></a>

### 4.2 Multiple VRC Buffers

This example continues the previous one.

* Open a new VRC buffer in a new tab

```
:tabe NewVrc.rest
```

* Since the new buffer has the extension 'rest', the VRC plug-in is active
    for this one.

* Set [vrc_output_buffer_name](#vrc_output_buffer_name) of this buffer to '__NEW_VRC__'

```
:let b:vrc_output_buffer_name = '__NEW_VRC__'
```

* Type in a request block such as

```http
http://localhost:9200
GET /testindex/_search?pretty|
```

* Hit the trigger key.
* A new display buffer will be created showing the response.
* Go back to the VRC buffer of the previous example (previous tab).
* Try to execute an existing request block.
* The corresponding display buffer will be updated.

<a id="VrcUsage"></a>

## 5. Usage

This plug-in is activated when Vim opens a buffer of type 'rest'. This may be
a file with the `.rest` or `.http` extension, or a buffer with `filetype`
explicitly set to 'rest' by

```
:set ft=rest
```

A VRC buffer can have one or many REST request blocks. A "request block"
contains a "host," "optional cUrl options," "optional headers," "query," and
an "optional request body" (usually used by POST). A block is defined as
follows.

```http
# host
http[s]://domain[:port]

[optional cUrl options]

[optional headers]

# query
POST /path/to/resource
[optional request body]
```

A comment starts with '#' or '//' and must be on its own line. The following
is an example of a VRC buffer with multiple request blocks.

```http
# GETting from resource.
http://example.com
GET /path/to/resource?key=value

# POSTing to an Elasticsearch service.
http://example.com/elasticsearch

// Specify optional headers.
Content-Type: application/json; charset=utf-8

POST /index/type?pretty
{
    "key": "a key",
    "value": "a value"
}

# Submitting a form.
https://example.net:8080

Accept: */*
Authorization: Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==
Cache-Control: no-cache
Connection: keep-alive
Content-Type: application/x-www-form-urlencoded
Cookie: userId=ac32:dfbe:8f1a:249c; sid=cfb48e3d98fcb1
User-Agent: VRC

POST /form
var1=value of var1&
var2=value of var2
```

When the trigger key is called (<C-j> by default), VRC processes the request
block that the cursor stays within. The response is displayed in a new
vertically split buffer. This output buffer is reused if it's already present.

The default trigger maps to <Plug>(vrc-query), so it can be remapped:

```vim
nnoremap <buffer> <C-k> <Plug>(vrc-query)
```

Use `:VrcQuery` to run a block without the mapping, or `:{range}VrcQuery` to
run every request block intersecting a range. Response bodies are formatted
and highlighted per request when a Content-Type or
[vrc_response_default_content_type](#vrc_response_default_content_type) is available.

By default, the display/output buffer is named '__REST_response__'. If there
are multiple VRC buffers, they all share the same display buffer. To have a
separate output display for each VRC buffer, [vrc_output_buffer_name](#vrc_output_buffer_name) can be
set in the buffer scope.

<a id="VrcCurlOptions"></a>

### 5.1 cUrl Options

A recent addition to VRC is the ability to specify cUrl options. These may be
specified by the VRC option [vrc_curl_opts](#vrc_curl_opts) or declaring in the global section
of a REST buffer (more at [VrcGlobalDefinitions](#VrcGlobalDefinitions)) and request blocks.

All specified cUrl options are merged together when a cUrl command is built.
For the same keys (cUrl switch) specified at different scopes, the ones of the
request blocks overwrite the ones in the global section then overwrite the
ones defined by [vrc_curl_opts](#vrc_curl_opts).

Option lines use simple shell-style quoting. Values containing spaces can be
wrapped in single or double quotes. Requests are executed directly without a
shell; `|` pipes, response handlers, and body preprocessors are shell commands
and use the 'shell' option.

For the deprecated VRC options, they can be replaced by cUrl options. For
example, assuming they have been defined as follows.

```vim
let g:vrc_connect_timeout = 10
let g:vrc_cookie_jar = '/path/to/cookie'
let g:vrc_follow_redirects = 1
let g:vrc_include_response_header = 1
let g:vrc_max_time = 60
let g:vrc_resolve_to_ipv4 = 1
let g:vrc_ssl_secure = 0
```

Using cUrl options,

```vim
let g:vrc_curl_opts = {
  \ '--connect-timeout' : 10,
  \ '-b': '/path/to/cookie',
  \ '-c': '/path/to/cookie',
  \ '-L': '',
  \ '-i': '',
  \ '--max-time': 60,
  \ '--ipv4': '',
  \ '-k': '',
\}
```

<a id="VrcGlobalDefinitions"></a>

### 5.2 Global Definitions

The global section is separated from the rest with two dashes `--` and may
include a default host, optional default cUrl options (buffer scope) and
optional default headers. These values are always included in each request.

Each request block has to start with either two dashes indicating it uses the
default host from the global section or any host only used by this block. If
a 'local host' is given, it's used instead of the one specified in the global
section. Additionally, a request block can specify extra cUrl options and
headers. Local headers are merged with and overwrite global headers.

```http
# Global definitions.
// Default host.
https://domain[:port]/...

// Default (buffer scope) cUrl options.
-L
--connect-timeout 10

// Default headers.
Accept: application/json
X-Header: Custom Data
--

# Request block that uses default values from the global section.
--
GET /some/query

# Request block that specifies its own host and extra headers.
// Local host.
https://example.net:9200

// Local cUrl opts.
-k
--ipv4
// This cUrl option overwrites the one in the global section.
--connect-timeout 30
-b /path/to/cookie
-c /path/to/cookie

// Extra headers.
Xtra-Header: Some Extra.
// This header will overwrite the one in the global section.
X-Header: New Data

POST /service
var1=value
```

<a id="VrcGlobalVarDecl"></a>

### 5.3 Global Variable Declaration

VRC supports variable declarations in the global scope. These variables can
be used in query paths, headers, and the request body. Values are not
URL-encoded. Values may contain static text or reference an environment
variable.

```http
# Global scope.
http://host

// Variable declarations (value passed as is).
foobar = LoremIpsum
city = Some%20City
zip = 12345
population = 42
restpassword = $SECRET_ENV_VAR
--
# End global scope.

--
GET /city/:city

--
GET /city/:city/zip/:zip

--
custom-header: :foobar
POST /city/:city
{ "population": :population }
```

<a id="VrcSplitRequestBody"></a>

### 5.4 Line-by-line Request Body

Since version 2.3.0, the request body can be specified on a line-by-line
basis. It's useful for name-value pair services. Each line of the request
body is passed to cURL using `--data` or `--data-urlencode` depending on
the verb.

To enable,

```vim
let g:vrc_split_request_body = 1
```

or

```vim
let b:vrc_split_request_body = 1
```

Then the request body can be specified as

```http
#
# The following params in the request body will be
# sent using `--data-urlencode`
#
http://localhost
Content-Type: text/html; charset=UTF-8
GET /service
var1=value1
var2=value2
```

This option won't take effect for `GET` request if the option
[vrc_allow_get_request_body](#vrc_allow_get_request_body) is set.

<a id="VrcConReqVerbs"></a>

### 5.5 Consecutive Request Verbs

A request block may have consecutive request verbs. The output of each request
verb is appended to the output view.

```http
http://localhost:9200
PUT /test
GET /test
DELETE /test
```

<a id="VrcResponseHandlers"></a>

### 5.6 Response Handlers

Response handlers parse a response and perform one of the following actions:
* substitute headers or global variables with values from the response
* send parse results to the quickfix list
* provide assertions that can abort later requests in the same block

A response handler is a comment with this format:

```
#{prefix}{target}<<{pattern}
```

{prefix} defines the scope, {target} defines what to do with the result, and
{pattern} is a shell command that consumes the response and produces the
result.

There are three handler types based on {target}:

<a id="VrcSubstitutionHandler"></a>

1. When {target} is a non-empty string, the handler is a substitution
handler. It replaces the remainder of the line with the {pattern} output. For
example, when {target} is "Authorization: ", the line defining the
Authorization header is replaced with the value extracted from the response.

<a id="VrcTraceHandler"></a>

2. When {target} is an empty string, the handler is a trace handler. It
sends all pattern results to the quickfix list.

<a id="VrcAssertionHandler"></a>

3. When {target} is `?`, the handler is an assertion handler. The output
of {pattern} is ignored, but its exit code is checked. A non-zero exit code
terminates execution of the current block. See the examples below.

{pattern} is any shell command that consumes the response and produces the
output used by {target}. Handler and pipe commands use the 'shell' option.

A handler's scope is defined by {prefix}:

* `>` - local scope. The handler consumes the output of the current request
and makes substitutions (for substitution handlers) only in the current block
and in the global section. Local handlers run automatically after the request
where they are defined. For an assertion handler, a non-zero exit code
terminates the current block.
* `%` - global scope. The handler consumes the whole VRC output buffer and
makes substitutions globally. It is ignored during normal request execution.
Use `:VrcHandleResponse` or `:call VrcHandleResponse()` for the current line
or selected region.

<a id="VrcResponseHandlersExamples"></a>

#### Examples

Local-scoped substitution handler used to set a request header value:

```http
http://somehost
Authorization: Bearer <TBD>
--
--
POST /token
#>Authorization: Bearer << jq -r '.access_token'

GET /protected_resource
```

The Authorization header is defined in the global scope. The first request
returns JSON with an `access_token` field, which can be used as a bearer token
for the protected resource. The handler runs immediately after the first
request, extracts the access token, and places it in the defined header. The
second request then uses that Authorization header.

Local-scoped substitution handler used to set a global variable value:

```http
http://somehost
userId=
--
--
GET /user
#>userId=<< jq -r '.id'

PUT /user/:userId
{
.....
}
```

The first request fetches the "user" resource. The handler extracts its `id`
from the response and places it in the `userId` global variable. The second
request uses that value to update the resource.

Local-scoped assertion handler:

```http
--
-i
GET /user

#>?<< grep "HTTP/" | grep "404"

POST /user/
{
....
}
```

The second request is executed only when the first response contains `404`.

Global-scoped handler used to extract the response codes of all requests:

```http
--
-i
GET /user/1
GET /user/2
GET /user/3

#%<< grep "HTTP/"
```

This handler is not executed automatically. Put the cursor on it (or select
it) and use `:VrcHandleResponse` or `:call VrcHandleResponse()`. The quickfix
list will show something like:

```
|144| HTTP/2 200
|144| HTTP/2 200
|144| HTTP/2 404
```

The first and second resources exist; the last one does not. These handlers
can be used to generate reports after executing a series of requests.

This handler receives the entire VRC output buffer as input.

You can automate the check further. For example, to ensure that every request
in a batch returned `200`:

```http
--
-i
GET /user/1
GET /user/2
GET /user/3

#%?<< [[ -z $(grep "HTTP/" | grep -v "200") ]]
```

The quickfix list will contain:

```
|145| True
```

when all requests returned `200`, or `False` otherwise. Visually select several
handlers and use `:VrcHandleResponse` (or `:call VrcHandleResponse()`) to run
them line by line; output is appended to the quickfix list.

<a id="VrcAsyncExecution"></a>

### 5.7 Asynchronous Execution

By default requests run synchronously. Set [vrc_async](#vrc_async) to run them in the
background:

```vim
let g:vrc_async = 1
```

Only one asynchronous run is active at a time. Additional triggers are queued
and executed sequentially. The output buffer is updated after each request
completes.

Cancel the active request and clear the queue with `:VrcCancel` or
<Plug>(vrc-cancel):

```vim
nnoremap <leader>vc <Plug>(vrc-cancel)
```

Timeout and cancellation abort the current run. Pipes and response handlers are
executed asynchronously. Body preprocessors remain synchronous.

<a id="VrcConfiguration"></a>

## 6. Configuration

VRC supports a few configurable variables. Each of them can have a global or
buffer scope (the latter takes priority). An option can be set in '.vimrc' for
the global scope by

```vim
let g:option_name = value
```

or in Vim for the buffer scope by

```vim
let b:option_name = value
```

<a id="vrc_allow_get_request_body"></a>
### `vrc_allow_get_request_body`

Allow GET request to have a request body or not. Default: 0.

If this option is set, `-X GET` is used and the request body is sent as a
single request body rather than as URL query parameters.

This option is useful for such services as Elasticsearch.

```http
#
# With vrc_allow_get_request_body = 1
#
http://localhost:9200
Content-Type: application/json

GET /testindex/testtype/_search
{
  "query": {
    "match": { "name": "FOO" }
  }
}
```

Be careful that when this option is enabled, the request body is always sent
as a whole regardless of [vrc_split_request_body](#vrc_split_request_body).

<a id="vrc_async"></a>
### `vrc_async`

Run requests asynchronously. Default: 0. Requires Vim's job and timer support.
Only one run is active globally; later triggers are queued.

```vim
let g:vrc_async = 1
let b:vrc_async = 1
```

Use `:VrcCancel` or <Plug>(vrc-cancel) to cancel the active run.

<a id="vrc_auto_format_response_enabled"></a>
### `vrc_auto_format_response_enabled`

This option enables the automatic formatting of the response. It's enabled by
default. To disable:

```vim
let g:vrc_auto_format_response_enabled = 0
```

If the response header is not present (i.e., no `-i` cUrl option), this option
depends on the option [vrc_response_default_content_type](#vrc_response_default_content_type).

<a id="vrc_auto_format_response_patterns"></a>
### `vrc_auto_format_response_patterns`

This option defines which external tools to use to auto-format the response
body according to the Content-Type.

The default patterns are selected at runtime:

```vim
    json: python3 -m json.tool, python -m json.tool, py -3 -m json.tool, or jq .
    xml:  xmllint --format -
>
An empty command disables formatting for that content type. User values are
merged with the defaults. For example:
>
    let g:vrc_auto_format_response_patterns = {
      \ 'json': '',
      \ 'xml': 'tidy -xml -i -',
    \}
```

If the response header isn't present (i.e., no `-i` cUrl option), this option
depends on the option [vrc_response_default_content_type](#vrc_response_default_content_type).

<a id="vrc_auto_format_uhex"></a>
### `vrc_auto_format_uhex`

If set, VRC will try to transform all unicode `\uXXXX` instances in the
response to the corresponding symbols, including surrogate pairs. It's turned
off by default.

<a id="vrc_body_preprocessor"></a>
### `vrc_body_preprocessor`

An external shell command to run using the request body as input. Its output
is used as the body for the request. Default is an empty string, which
disables preprocessing. The command uses the 'shell' option.

Example using yaml2json to convert from yaml (easier to type) to JSON,
and then piping into jq minify that:

```vim
let g:vrc_body_preprocessor = 'yaml2json | jq -c .'
```

<a id="vrc_curl_opts"></a>
### `vrc_curl_opts`

A dictionary that contains the default cUrl options. Default: not set.

```vim
let g:vrc_curl_opts = {
  \ '-sS': '',
  \ '--connect-timeout': 10,
  \ '-H': ['header1: value1', 'header2: value2'],
\}
```

An empty string means the option has no value. Empty lists are ignored.
Numeric values, including 0, are passed through.

<a id="vrc_debug"></a>
### `vrc_debug`

This option enables the debug mode by adding the '-v' option to the 'curl'
command and also `echom` the command to the Vim console. It's turned off by
default.

<a id="vrc_elasticsearch_support"></a>
### `vrc_elasticsearch_support`

If enabled, the data of Elasticsearch's `_bulk` API can also be specified
directly in the request block instead of indirectly via an external file.
It's off by default.

<a id="vrc_header_content_type"></a>
### `vrc_header_content_type`

This option is to set the header content type of the request. It defaults to
'application/json'. To set a different default content type,

```vim
let g:vrc_header_content_type = 'application/x-www-form-urlencoded'
```

It can also be set in the buffer scope by

```vim
let b:vrc_header_content_type = 'application/json; charset=utf-8'
```

If 'Content-Type' is specified in the request block, it overrides this
setting.

<a id="vrc_horizontal_split"></a>
### `vrc_horizontal_split`

By default, the output buffer is displayed to the right of the rest buffer
(vertical split). If this option is set, the output buffer is displayed
below the rest buffer.

<a id="vrc_keepalt"></a>
### `vrc_keepalt`

By default, the current alternate file name will be changed. If this
option is set, it will keep the current alternate file.

<a id="vrc_output_buffer_name"></a>
### `vrc_output_buffer_name`

This option sets the name for the output/display buffer. By default, it's set
to '__REST_response__'. To assign a different name,

```vim
let g:vrc_output_buffer_name = '__NEW_NAME__'
```

This option is useful in working with multiple VRC buffers where each one has
its own output display. For this, the option can be set in the buffer scope as

```vim
let b:vrc_output_buffer_name = '__REST_1_OUTPUT__'
```

<a id="vrc_response_default_content_type"></a>
### `vrc_response_default_content_type`

This option is to set the default content type of the response. It's useful
when we don't want to include the response header in the output view but
still want the output to be formatted or syntax-highlighted.

```vim
let b:vrc_response_default_content_type = 'application/json'
```

or

```vim
let g:vrc_response_default_content_type = 'text/xml'
```

<a id="vrc_set_default_mapping"></a>
### `vrc_set_default_mapping`

This option is to enable/disable the trigger key mapping. It's enabled by
default. To disable the mapping,

```vim
let g:vrc_set_default_mapping = 0
```

Once the mapping is disabled, the request block can be executed by

```
:VrcQuery
:{range}VrcQuery
:call VrcQuery()
```

<a id="vrc_show_command"></a>
### `vrc_show_command`

This option enables the printing of the executed curl command in the quickfix
list (or result buffer, see [vrc_show_command_in_result_buffer](#vrc_show_command_in_result_buffer)). It's
disabled by default. To enable:

```vim
let g:vrc_show_command = 1
```

<a id="vrc_show_command_in_quickfix"></a>
### `vrc_show_command_in_quickfix`

This option controls whether executed curl commands are shown in the quickfix
list. It's enabled by default. To disable:

```vim
let g:vrc_show_command_in_quickfix = 0
```

<a id="vrc_curl_timeout"></a>
### `vrc_curl_timeout`

Kill the curl job after this timeout. Default: '1m'. Values may use the `ms`,
`s`, `m`, or `h` suffix; plain numbers are seconds. Set it to 0 or an empty
string to disable the timeout. VRC uses its own job timeout, so no external
`timeout` program is required.

```vim
let g:vrc_curl_timeout = '5s'
let g:vrc_curl_timeout = '500ms'
```

<a id="vrc_show_command_in_result_buffer"></a>
### `vrc_show_command_in_result_buffer`

This option enables the printing of the executed curl command in the output
pane. It's disabled by default. To enable:

```vim
let g:vrc_show_command_in_result_buffer = 1
```

<a id="vrc_split_request_body"></a>
### `vrc_split_request_body`

Determine if the request body should be processed line by line. Default: 0.

If this option is set, each line of the request body is passed to cURL using
either `--data` or `--data-urlencode` depending on the verb. For GET, HEAD, and
DELETE, the values are sent as URL query parameters.

If the verb is `GET` and the option [vrc_allow_get_request_body](#vrc_allow_get_request_body) is enabled,
this option doesn't take effect; the request body is always sent as a whole
using `--data`.

<a id="vrc_syntax_highlight_response"></a>
### `vrc_syntax_highlight_response`

This option enables the syntax highlighting of the response body according to
the Content-Type. It's enabled by default. To disable:

```vim
let g:vrc_syntax_highlight_response = 0
```

If the response header isn't present (i.e., no `-i` cUrl option), this option
depends on the option [vrc_response_default_content_type](#vrc_response_default_content_type).

<a id="vrc_trigger"></a>
### `vrc_trigger`

This option defines the trigger key. It's <C-j> by default and maps to
<Plug>(vrc-query). To remap the key:

```vim
let g:vrc_trigger = '<C-k>'
```

You can also map the plug directly:

```vim
nnoremap <buffer> <C-k> <Plug>(vrc-query)
xnoremap <buffer> <C-k> <Plug>(vrc-query)
```

<a id="VrcTnt"></a>

## 7. Tips 'n Tricks

<a id="VrcTntDataBulk"></a>

### 7.1 POST Data in Bulk

Since v3.0, VRC supports POSTing data in bulk using in-line data or an
external data file. It's helpful for such APIs as Elasticsearch's Bulk API.

To use in-line data, first enable the Elasticsearch support flag.

```vim
let g:vrc_elasticsearch_support = 1
```

The request would look like this.

```http
http://localhost:9200
POST /testindex/_bulk
{ "index": { "_index": "test", "_type": "product" } }
{ "sku": "SKU1", "name": "Product name 1" }
{ "index": { "_index": "test", "_type": "product" } }
{ "sku": "SKU2", "name": "Product name 2" }
```

Using external data files doesn't need the support flag.

```http
http://localhost:9200
POST /testindex/_bulk
@data.sample.json
```

Relative paths are resolved against the directory of the `.rest` buffer.

<a id="VrcTntStxHi"></a>

### 7.2 Syntax Highlighting

VRC highlights responses based on the response Content-Type. When the server
does not send a Content-Type, set a default so formatting and highlighting
still work:

```vim
let g:vrc_response_default_content_type = 'application/json'
```

You can also set the filetype manually in the output buffer:

```
:setlocal ft=json
```

<a id="VrcContributors"></a>

## 8. Contributors

Thanks to the contributors (in alphabetical order of GitHub account)

```
@dan-silva
@dflupu
@iamFIREcracker
@jojoyuji
@korin
@minhajuddin
@mjakl
@nathanaelkane
@p1otr
@rawaludin
@rlisowski
@sethtrain
@shanesmith
@tdroxler
@tonyskn
@torbjornvatn
```

<a id="VrcLicense"></a>

## 9. License

MIT
