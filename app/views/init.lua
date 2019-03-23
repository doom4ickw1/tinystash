local exit = require('app.utils').exit
local render_to_string = require('app.views.helpers').render_to_string


local template_handler_meta = {
  __call = function(self)
    if self.content then
      ngx.print(self.content)
      return
    end
    local content = render_to_string(self.template, self.context)
    if self.cache then
      self.content = content
    end
    ngx.print(content)
  end
}


local template_handler = function(params)
  -- params table:
  -- [1] = template path
  -- [2] = context (optional)
  -- content_type = <not set>
  -- cache = true
  local cache = params.cache
  if cache == nil then
    cache = true
  end
  local content_type = params.content_type
  if content_type then
    ngx.header['content-type'] = content_type
  end
  return setmetatable({
    template = params[1],
    context = params[2],
    cache = cache,
  }, template_handler_meta)
end


local view_meta = {
  __call = function(self, ...)
    local args
    if self.initial then
      args = {self.initial(...)}
    else
      args = {...}
    end
    local method = ngx.req.get_method()
    local handler = self[method]
    if not handler then
      exit(ngx.HTTP_NOT_ALLOWED)
    else
      handler(unpack(args))
    end
  end
}


local view = function(handlers)
  local view_table = {}
  for method, handler in pairs(handlers) do
    local handler_type = type(handler)
    if method == 'initial' then
      assert(handler_type == 'function')
      view_table.initial = handler
    else
      if handler_type == 'table' then
        handler = template_handler(handler)
      elseif handler_type == 'string' then
        handler = template_handler({handler})
      end
      view_table[method:upper()] = handler
    end
  end
  return setmetatable(view_table, view_meta)
end


local viewset = function(views)
  local viewset_table = {}
  for name, view_ in pairs(views) do
    viewset_table[name] = view(view_)
  end
  return viewset_table
end


return viewset{
  main = require('app.views.main'),
  getfile = require('app.views.getfile'),
  webhook = require('app.views.webhook'),
  upload = require('app.views.upload'),
}