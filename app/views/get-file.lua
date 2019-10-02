local tinyid = require('app.tinyid')
local utils = require('app.utils')
local constants = require('app.constants')
local tg = require('app.tg')
local helpers = require('app.views.helpers')


local ngx_print = ngx.print
local ngx_header = ngx.header
local ngx_INFO = ngx.INFO
local ngx_ERR = ngx.ERR
local ngx_HTTP_OK = ngx.HTTP_OK
local ngx_HTTP_NOT_FOUND = ngx.HTTP_NOT_FOUND
local ngx_HTTP_BAD_GATEWAY = ngx.HTTP_BAD_GATEWAY

local log = utils.log
local error = utils.error
local escape_uri = utils.escape_uri
local guess_extension = utils.guess_extension
local parse_media_type = utils.parse_media_type

local prepare_connection = tg.prepare_connection
local request_tg_server = tg.request_tg_server

local render_link_factory = helpers.render_link_factory
local render = helpers.render

local TG_TYPES = constants.TG_TYPES
local TG_TYPES_EXTENSIONS_MAP = constants.TG_TYPES_EXTENSIONS_MAP
local GET_FILE_MODES = constants.GET_FILE_MODES
local CHUNK_SIZE = constants.CHUNK_SIZE


return {

  GET = function(tiny_id, mode, file_name)
    -- decode tiny_id
    local tiny_id_params, tiny_id_err = tinyid.decode(tiny_id)
    if not tiny_id_params then
      log(ngx_INFO, 'tiny_id decode error: %s', tiny_id_err)
      return error(ngx_HTTP_NOT_FOUND)
    end

    local conn, res, err, params
    conn, err = prepare_connection()
    if not conn then
      log(ngx_ERR, 'tg api connection error: %s', err)
      return error(ngx_HTTP_BAD_GATEWAY)
    end

    -- get file info
    params = {
      path = '/bot%s/getFile',
      query = 'file_id=' .. tiny_id_params.file_id,
    }
    res, err = request_tg_server(conn, params, true)
    if not res then
      log(ngx_ERR, 'tg api request error: %s', err)
      return error(ngx_HTTP_BAD_GATEWAY)
    end
    if not res.ok then
      log(ngx_INFO, 'tg api response is not "ok": %s', res.description)
      return error(ngx_HTTP_NOT_FOUND)
    end

    local file_path = res.result.file_path
    local file_size = res.result.file_size
    local media_type = tiny_id_params.media_type or 'application/octet-stream'
    local extension
    -- fix voice message file .oga extension
    if file_path:match('^voice/.+%.oga$') then
      extension = '.' .. TG_TYPES_EXTENSIONS_MAP[TG_TYPES.VOICE]
    else
      extension = guess_extension{
        file_name = file_path,
        media_type = media_type,
      }
    end

    -- /ln/ -> render links page

    if mode == GET_FILE_MODES.LINKS then
      render('web/file-links.html', {
        title = tiny_id,
        file_size = file_size,
        media_type = media_type,
        modes = GET_FILE_MODES,
        render_link = render_link_factory(tiny_id),
        extension = extension,
      })
      return
    end

    -- /dl/ or /il/ -> stream file content from tg file storage

    -- connect to tg file storage
    params = {
      path = escape_uri('/file/bot%s/' .. file_path),
    }
    res, err = request_tg_server(conn, params)
    if not res then
      log(ngx_ERR, 'tg file storage request error: %s', err)
      conn:set_keepalive()
      return error(ngx_HTTP_BAD_GATEWAY)
    end
    if res.status ~= ngx_HTTP_OK then
      log(ngx_ERR, 'tg file storage response status %s != 200', res.status)
      conn:set_keepalive()
      return error(ngx_HTTP_NOT_FOUND)
    end

    if not file_name or #file_name < 1 then
      file_name = tiny_id .. (extension or '')
    end
    local content_disposition
    if mode == GET_FILE_MODES.DOWNLOAD then
      content_disposition = 'attachment'
    else
      content_disposition = 'inline'
    end

    local content_type = media_type
    if parse_media_type(media_type)[1] == 'text' then
      content_type = content_type .. '; charset=utf-8'
    end
    ngx_header['content-type'] = content_type
    ngx_header['content-disposition'] = ("%s; filename*=utf-8''%s"):format(
      content_disposition, escape_uri(file_name, true))
    ngx_header['content-length'] = file_size

    local chunk
    while true do
      chunk, err = res.body_reader(CHUNK_SIZE)
      if err then
        log(ngx_ERR, 'tg file storage read error: %s', err)
        break
      end
      if not chunk then break end
      ngx_print(chunk)
    end

    conn:set_keepalive()

  end

}