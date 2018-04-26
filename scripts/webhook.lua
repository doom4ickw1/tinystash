local http = require('resty.http')
local json = require('cjson.safe')

local config = require('config.app')
local tg = config.tg


local assume_yes = false
local verbose = false

local die = function(...)
  print(...)
  os.exit(1)
end

if not tg or not tg.token then
  die('Bad config: set tg.token')
end

local verbose_print = function(...)
  if verbose then
    print(...)
  end
end

local show_help = function()
  print([[Usage:
  webhook get           get current webhook status
  webhook set           set webhook to <link_url_prefix>/webhook/<secret>
  webhook set PREFIX    set webhook to PREFIX/<secret>
  webhook delete        delete webhook
  webhook -h            show this help

Options:
  -v                    verbose mode
  -y                    assume yes

<link_url_prefix>       'link_url_prefix' config parameter
<secret>                one of 'tg' table config parameters:
                        - 'webhook_secret' (if any)
                        - 'token' if 'webhook_secret' not set
]])
  os.exit(0)
end

local arguments = {}
for _, argument in ipairs(arg) do
  if argument:sub(1, 1) == '-' then
    if argument == '-h' then
      show_help()
    elseif argument == '-y' then
      assume_yes = true
    elseif argument == '-v' then
      verbose = true
    else
      die('Invalid option: ', argument)
    end
  else
    table.insert(arguments, argument)
  end
end

local ask = function()
  if assume_yes then
    return
  end
  io.stdout:write('Are you sure (yes/no)? ')
  io.stdout:flush()
  if io.stdin:read() ~= 'yes' then
    die('Abort')
  end
end

local api_call = function(method, params)
  local res, err
  local uri = ('https://api.telegram.org/bot%s/%s'):format(tg.token, method)
  local httpc = http.new()
  httpc:set_timeout(10000)
  res, err = httpc:request_uri(uri, {
    query = params,
    ssl_verify = false,
  })
  if not res then
    die('TG API request error: ', err)
  end
  verbose_print('TG API response status: ', res.status)
  verbose_print('TG API response body: ', res.body)
  res, err = json.decode(res.body)
  if not res then
    die('TG API response json decode error: ', err)
  end
  if not res.ok then
    die('TG API response error: ', res.description)
  end
  print('OK')
  if res.description then
    print(res.description)
  end
  return res
end

local cmd = arguments[1]
if cmd == 'get' then
  local res = api_call('getWebhookInfo')
  local webhook_url = res.result.url
  if webhook_url and webhook_url ~= '' then
    print('Current webhook: ', webhook_url)
  else
    print('Webhook not set')
  end
elseif cmd == 'set' then
  local url_prefix = arguments[2]
  if not url_prefix then
    local link_url_prefix = config.link_url_prefix
    if not link_url_prefix then
      die([[Webhook URL prefix not specified
Set 'link_url_prefix' in config or pass prefix as command line argument]])
    end
    url_prefix = ('%s/webhook'):format(link_url_prefix:match('(.-)/*$'))
  end
  local secret = tg.webhook_secret or tg.token
  local url = ('%s/%s'):format(url_prefix:match('(.-)/*$'), secret)
  print('Set webhook to ', url)
  ask()
  api_call('setWebhook', {url = url})
elseif cmd == 'delete' then
  print('Delele current webhook')
  ask()
  api_call('deleteWebhook')
else
  show_help()
end
