local upload = require('resty.upload')
local template = require('resty.template')

local tinyid = require('app.tinyid')
local tg = require('app.tg')
local utils = require('app.utils')
local constants = require('app.constants')
local render_link_factory = require('app.views.helpers').render_link_factory
local tg_upload_chat_id = require('config.app').tg.upload_chat_id

local yield = coroutine.yield

local log = utils.log
local exit = utils.exit
local generate_random_hex_string = utils.generate_random_hex_string
local parse_media_type = utils.parse_media_type
local normalize_media_type = utils.normalize_media_type
local get_media_type_id = utils.get_media_type_id
local guess_extension = utils.guess_extension

local CHUNK_SIZE = constants.CHUNK_SIZE
local TG_MAX_FILE_SIZE = constants.TG_MAX_FILE_SIZE

local prepare_connection = tg.prepare_connection
local request_tg_server = tg.request_tg_server
local get_file_from_message = tg.get_file_from_message


local format_error = function(preamble, error)
  if not error then
    return preamble
  end
  return ('%s: %s'):format(preamble, error)
end


local yield_chunk = function(bytes)
  -- yield chunked transfer encoding chunk
  if bytes == nil then bytes = '' end
  yield(('%X\r\n%s\r\n'):format(#bytes, bytes))
end


local FIELD_NAME_FILE = 'file'
local FIELD_NAME_CSRFTOKEN = 'csrftoken'

local get_form_field_name = function(content_disposition)
  return content_disposition:match('[ ;]name="([^"]+)"')
end


local uploader_meta = {}
uploader_meta.__index = uploader_meta

local prepare_uploader = function(upload_type, chat_id)
  local form, err = upload:new(CHUNK_SIZE)
  if not form then
    return nil, err
  end
  form:set_timeout(1000) -- 1 sec
  local expected_form_fields = {
    [FIELD_NAME_FILE] = true,
    [FIELD_NAME_CSRFTOKEN] = true,
  }
  return setmetatable({
    upload_type = upload_type,
    chat_id = chat_id,
    expected_form_fields = expected_form_fields,
    form = form,
    -- bytes_uploaded = nil | number (set by upload_body_coro)
    -- media_type = nil | string (set by run)
  }, uploader_meta)
end

uploader_meta.close = function(self)
  if self.conn then
    self.conn:set_keepalive()
  end
end

uploader_meta.run = function(self)
  -- returns:
  --   if ok: TG API object (Document/Video/...) table with mandatory 'file_id' field
  --   if error: nil, error_code, error_text?
  -- sets:
  --  self.media_type: string
  local file_object
  local res, err
  while true do
    res, err = self:handle_form_field()
    if not res then
      log(err)
      return nil, ngx.HTTP_BAD_REQUEST, err
    elseif res == ngx.null then
      log('end of form')
      break
    else
      local field_name, media_type, initial_data = unpack(res)
      if not self.expected_form_fields[field_name] then
        return nil, ngx.HTTP_BAD_REQUEST, format_error('unexpected form field', field_name)
      end
      if field_name == FIELD_NAME_FILE then
        if initial_data:len() == 0 then
          return nil, ngx.HTTP_BAD_REQUEST, 'empty file'
        end
        if self.upload_type == 'text' then
          media_type = 'text/plain'
        elseif not media_type then
          media_type = 'application/octet-stream'
        else
          media_type = normalize_media_type(media_type)
        end
        self.media_type = media_type
        log('media type: %s', media_type)
        file_object, err = self:upload(initial_data)
        if not file_object then
          return nil, ngx.HTTP_INTERNAL_SERVER_ERROR, err
        end
      end
    end
  end
  if not file_object then
    return nil, ngx.HTTP_BAD_REQUEST, 'no file'
  end
  return file_object
end

uploader_meta.handle_form_field = function(self)
  -- returns:
  --  if eof: ngx.null
  --  if body (any): first chunk of body ("initial_data")
  --  if error (any): nil, error_code, error_text?
  local form = self.form
  local field_name, media_type
  local token, data, err
  while true do
    token, data, err = form:read()
    -- 'part_end' tokens are ignored
    if not token then
      return nil, err
    elseif token == 'eof' then
      return ngx.null
    elseif token == 'header' then
      if type(data) ~= 'table' then
        return nil, 'invalid form-data part header'
      end
      local header = data[1]:lower()
      local value = data[2]
      if header == 'content-type' then
        media_type = value
      elseif header == 'content-disposition' then
        field_name = get_form_field_name(value)
      end
    elseif token == 'body' and field_name then
      return {field_name, media_type, data}
    end
  end
end

uploader_meta.upload = function(self, initial)
  -- initial: string or nil, first chunk of file
  -- returns:
  --  if ok: table -- TG API object (Document/Video/...) table
  --  if error: nil, err
  -- sets:
  --  self.boundary: string
  local boundary = 'BNDR-' .. generate_random_hex_string(32)
  self.boundary = boundary
  local conn, res, err
  conn, err = prepare_connection()
  if not conn then
    return nil, err
  end
  self.conn = conn
  local upload_body_iterator = self:get_upload_body_iterator(initial)
  local params = {
    path = '/bot%s/sendDocument',
    method = 'POST',
    headers = {
      ['content-type'] = 'multipart/form-data; boundary=' .. boundary,
      ['transfer-encoding'] = 'chunked',
    },
    body = upload_body_iterator,
  }
  res, err = request_tg_server(conn, params, true)
  if not res then
    return nil, format_error('tg api request error', err)
  end
  if not res.ok then
    return nil, format_error('tg api response is not "ok"', res.description)
  end
  if not res.result then
    return nil, 'tg api response has no "result"'
  end
  local file
  file, err = get_file_from_message(res.result)
  if not file then
    return nil, err
  end
  local file_object = file.object
  if not file_object.file_id then
    return nil, 'tg api response has no file_id'
  end
  return file_object
end

uploader_meta.get_upload_body_iterator = function(self, initial)
  local iterator = coroutine.wrap(self.upload_body_coro)
  -- pass function arguments in the first call (priming)
  iterator(self, initial)
  return iterator
end

uploader_meta.upload_body_coro = function(self, initial)
  -- sets:
  --   self.bytes_uploaded: number
  -- send nothing on first call (iterator priming)
  yield(nil)
  local media_type = self.media_type
  local boundary = self.boundary
  local sep = ('--%s\r\n'):format(boundary)
  local ext = guess_extension{media_type = media_type, exclude_dot = true} or 'bin'
  local filename = ('%s.%s'):format(generate_random_hex_string(16), ext)
  yield_chunk(sep)
  yield_chunk('content-disposition: form-data; name="chat_id"\r\n\r\n')
  yield_chunk(('%s\r\n'):format(self.chat_id))
  yield_chunk(sep)
  yield_chunk(('content-disposition: form-data; name="document"; filename="%s"\r\n'):format(filename))
  yield_chunk(('content-type: %s\r\n\r\n'):format(media_type))
  local bytes_uploaded = 0
  if initial then
    -- first chunk of the file
    yield_chunk(initial)
    bytes_uploaded = bytes_uploaded + #initial
  end
  local form = self.form
  local token, data, err
  while true do
    token, data, err = form:read()
    if not token then
      log(ngx.ERR, 'failed to read next form chunk: %s', err)
      break
    elseif token == 'body' then
      yield_chunk(data)
      bytes_uploaded = bytes_uploaded + #data
    elseif token == 'part_end' then
      break
    else
      log(ngx.ERR, 'unexpected token: %s', token)
      break
    end
  end
  yield_chunk(('\r\n--%s--\r\n'):format(boundary))
  yield_chunk(nil)
  self.bytes_uploaded = bytes_uploaded
end


return {

  initial = function(upload_type)
    if not tg_upload_chat_id then
      exit(ngx.HTTP_NOT_FOUND)
    end
    if upload_type == '' then
      upload_type = 'file'
    end
    return upload_type
  end,

  GET = function(upload_type)
    template.render('web/upload.html', {
      upload_type = upload_type,
    })
  end,

  POST = function(upload_type)
    ngx.header['content-type'] = 'text/plain'
    local uploader, err = prepare_uploader(upload_type, tg_upload_chat_id)
    if not uploader then
      log('failed to init uploader: %s', err)
      exit(ngx.HTTP_BAD_REQUEST)
    end
    local file_object, err_code
    file_object, err_code, err = uploader:run()
    uploader:close()
    if not file_object then
      exit(err_code, err)
    end
    local file_size = file_object.file_size
    local bytes_uploaded = uploader.bytes_uploaded
    if file_size and file_size ~= bytes_uploaded then
      log(ngx.WARN, 'size mismatch: file_size: %d, bytes uploaded: %d',
          file_size, bytes_uploaded)
    else
      log('bytes uploaded: %s', bytes_uploaded)
    end
    if (file_size or bytes_uploaded) > TG_MAX_FILE_SIZE then
      log('file is too big for getFile API method, return error to client')
      exit(413)
    end
    local media_type = uploader.media_type
    local media_type_id = get_media_type_id(media_type)
    if not media_type_id then
      local media_type_table = parse_media_type(media_type)
      if media_type_table[1] == 'text' then
        media_type_id = get_media_type_id('text/plain')
      end
    end
    local tiny_id
    tiny_id, err = tinyid.encode{
      file_id = file_object.file_id,
      media_type_id = media_type_id,
    }
    if not tiny_id then
      log(ngx.ERR, 'failed to encode tiny_id: %s', err)
      exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    ngx.redirect(render_link_factory(tiny_id)('ln'), ngx.HTTP_SEE_OTHER)
  end

}
