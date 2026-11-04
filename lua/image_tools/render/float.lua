-- Generic image floats for external producers. The host owns its source file
-- and selection authority; this handle owns layout, pixels and editor resources.
local M = {}
local Float = {}
Float.__index = Float

function Float:close()
  if self.closed then
    return
  end
  self.closed = true
  if self.group then
    vim.api.nvim_del_augroup_by_id(self.group)
    self.group = nil
  end
  self.preview:destroy()
  if self.request.on_close then
    self.request.on_close()
  end
end
Float.destroy = Float.close

function Float:status()
  local state = self.preview.state
  return {
    closed = self.closed == true,
    error = self.error,
    window = state and state.win,
    stage = state and state.render and state.render.stage,
  }
end

function Float:current()
  if self.closed or not vim.api.nvim_win_is_valid(self.owner_win) then
    return false
  end
  if self.request.is_valid then
    local ok, valid = pcall(self.request.is_valid)
    return ok and valid == true
  end
  return true
end

function Float:resize()
  if not self:current() then
    self:close()
    return
  end
  -- Closing the old placement during a resize must not close the host handle.
  local state = self.preview.state
  if state then
    state.on_close = nil
  end
  local accepted, err = self.preview:open(self.path, self.open_options)
  if not accepted then
    self:close()
    if self.request.on_error then
      self.request.on_error(err)
    end
  end
end

---@param request table path, display_size?, title?, is_valid?, on_error?, on_close?, and optional layout overrides.
function M.new(request, options, dependencies)
  if type(request) ~= "table" or type(request.path) ~= "string" or request.path == "" then
    return nil, "float requires a local image path"
  end
  for _, name in ipairs({ "is_valid", "on_error", "on_close" }) do
    if request[name] ~= nil and type(request[name]) ~= "function" then
      return nil, name .. " must be a function"
    end
  end
  if request.title ~= nil and type(request.title) ~= "string" then
    return nil, "title must be a string"
  end
  if request.display_size then
    for _, name in ipairs({ "width", "height" }) do
      local value = type(request.display_size) == "table" and request.display_size[name]
      if type(value) ~= "number" or value ~= value or value <= 0 or value >= math.huge then
        return nil, "display_size must contain positive finite width and height"
      end
    end
  end
  local layout = {}
  for _, name in ipairs({ "position", "right_padding", "max_width", "max_height", "border" }) do
    layout[name] = request[name]
  end
  local ok, resolved = pcall(require("image_tools.config").resolve, vim.tbl_extend("force", options, layout))
  if not ok then
    return nil, tostring(resolved)
  end
  local self = setmetatable({
    request = request,
    path = vim.fs.normalize(vim.fn.fnamemodify(request.path, ":p")),
    owner_win = vim.api.nvim_get_current_win(),
    owner_buf = vim.api.nvim_get_current_buf(),
    preview = require("image_tools.render.preview").new(resolved, dependencies),
  }, Float)
  self.open_options = {
    silent = true,
    display_size = request.display_size,
    title = request.title,
    _external = {
      is_valid = function()
        return self:current()
      end,
      on_close = function()
        self:close()
      end,
      on_error = function(err)
        self.error = tostring(err)
        if request.on_error then
          request.on_error(self.error)
        end
        self:close()
      end,
    },
  }
  local accepted, err = self.preview:open(self.path, self.open_options)
  if not accepted or self.closed then
    self:close()
    return nil, err or "Image float closed during preparation"
  end
  self.group =
    vim.api.nvim_create_augroup("ImageToolsFloat" .. tostring(self.owner_win) .. "_" .. tostring(self.preview), {})
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI" }, {
    group = self.group,
    callback = function()
      if not self:current() then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "WinClosed", "BufWipeout" }, {
    group = self.group,
    callback = function(event)
      local win = tonumber(event.match)
      if
        (event.event == "WinClosed" and (win == self.owner_win or win == (self.preview.state or {}).win))
        or (event.event == "WinLeave" and vim.api.nvim_get_current_win() == self.owner_win)
        or (event.event ~= "WinClosed" and event.event ~= "WinLeave" and event.buf == self.owner_buf)
      then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "WinScrolled" }, {
    group = self.group,
    callback = function()
      vim.schedule(function()
        if not self.closed then
          self:resize()
        end
      end)
    end,
  })
  return self
end

return M
