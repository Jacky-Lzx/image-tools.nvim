-- Borrow a host-owned scratch pane. Own only this view's media session,
-- placement leases, placeholder marks and temporary window options.
---@class ImageToolsEmbeddedRequest
---@field path string Local image/PDF path.
---@field buf integer Caller-owned nofile scratch buffer.
---@field win integer Window already displaying buf.
---@field page? integer PDF page override.
---@field previous? ImageToolsEmbeddedView Retained view of this same pane.
---@field upscale? boolean Fit small images to the pane; default true.
---@field render_scale? number Converted-raster detail multiplier in [1, 8]; independent of pane size.
---@field display_size? ImageToolsImageSize Logical dimensions independent of raster sampling density.
---@field is_valid? fun(): boolean Host generation/selection authority.
---@field paint? fun(draw: fun(): boolean): boolean? Synchronous host drawing transaction.
---@field on_error? fun(error: string) Asynchronous failure callback.
---@class ImageToolsEmbeddedView: ImageToolsDrawState
---@field closed? boolean
---@field error? string
---@field resize fun(self: ImageToolsEmbeddedView)
---@field retain fun(self: ImageToolsEmbeddedView): ImageToolsEmbeddedView?
---@field close fun(self: ImageToolsEmbeddedView)
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("image_tools.embedded")
local serial = 0
local owners = setmetatable({}, { __mode = "v" })
local View = {}
View.__index = View
local modules = { image = "image_tools.media", protocol = "image_tools.terminal.protocol" }
local window_options = {
  number = false,
  relativenumber = false,
  wrap = false,
  list = false,
  spell = false,
  conceallevel = 0,
  winblend = 0,
  cursorline = false,
  cursorcolumn = false,
  signcolumn = "no",
  foldcolumn = "0",
}

function View:dependency(name)
  return self.dependencies[name] or require(modules[name] or ("image_tools." .. name))
end
function View:current()
  local owner = owners[self.buf]
  local owned = owner == self or (self.retained and owner and owner.previous == self)
  if
    self.closed
    or not owned
    or not api.nvim_buf_is_valid(self.buf)
    or not api.nvim_win_is_valid(self.win)
    or api.nvim_win_get_buf(self.win) ~= self.buf
  then
    return false
  end
  if self.retained then
    return true
  end
  if self.request.is_valid then
    local ok, valid = pcall(self.request.is_valid)
    return ok and valid == true
  end
  return true
end
function View:viewport()
  local info = vim.fn.getwininfo(self.win)[1] or {}
  return math.max(1, api.nvim_win_get_width(self.win) - (info.textoff or 0)), api.nvim_win_get_height(self.win)
end
-- The host may wrap the synchronous transaction to record preview metadata.
function View:paint(draw)
  if self.retained or not self:current() then
    return false
  end
  local function transaction()
    if not self:current() then
      return false
    end
    local modifiable, readonly, modified =
      vim.bo[self.buf].modifiable, vim.bo[self.buf].readonly, vim.bo[self.buf].modified
    vim.bo[self.buf].readonly, vim.bo[self.buf].modifiable = false, true
    local ok, err = pcall(draw)
    if api.nvim_buf_is_valid(self.buf) then
      vim.bo[self.buf].modified = modified
      vim.bo[self.buf].modifiable, vim.bo[self.buf].readonly = modifiable, readonly
    end
    if not ok then
      error(err)
    end
    return true
  end
  if self.request.paint then
    return self.request.paint(transaction) ~= false
  end
  return transaction()
end
function View:release(keep_previous)
  if self.session then
    self.session:close()
    self.session = nil
  end
  local grid = self.grid or (not keep_previous and self.previous_grid)
  if (grid or self.highlight) and api.nvim_buf_is_valid(self.buf) and owners[self.buf] == self then
    api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    -- Do not erase content installed by a new owner or by the host itself.
    if grid and vim.deep_equal(api.nvim_buf_get_lines(self.buf, 0, -1, false), grid) then
      local writable, modified = vim.bo[self.buf].modifiable, vim.bo[self.buf].modified
      vim.bo[self.buf].modifiable = true
      api.nvim_buf_set_lines(self.buf, 0, -1, false, { "" })
      vim.bo[self.buf].modified, vim.bo[self.buf].modifiable = modified, writable
    end
  end
  if self.highlight then
    require("image_tools.render.placeholder").clear(self)
  end
  self.grid, self.id, self.placement_id, self.highlight = nil, nil, nil, nil
  if not keep_previous then
    self.previous_grid = nil
  end
end
function View:close()
  if self.closed then
    return
  end
  self.closed = true
  self:release()
  self.transfer:clear()
  if self.group then
    pcall(api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
  local previous = self.previous
  self.previous = nil
  if owners[self.buf] == self then
    if previous and not previous.closed then
      owners[self.buf] = previous
      previous:close()
    else
      owners[self.buf] = nil
      if api.nvim_win_is_valid(self.win) and api.nvim_win_get_buf(self.win) == self.buf then
        for name, value in pairs(self.saved_options) do
          if vim.wo[self.win][name] == window_options[name] then
            vim.wo[self.win][name] = value
          end
        end
      end
    end
  elseif previous then
    previous:close()
  end
end
View.destroy = View.close
-- Freeze a completed frame, or cancel pending work and return its ready ancestor.
-- A frozen view cannot start new draws; its leases survive until close/replacement.
function View:retain()
  if
    self.closed
    or owners[self.buf] ~= self
    or not api.nvim_buf_is_valid(self.buf)
    or not api.nvim_win_is_valid(self.win)
    or api.nvim_win_get_buf(self.win) ~= self.buf
  then
    self:close()
    return nil
  end
  if self.grid and self.session and self.session.stage == "ready" then
    self.retained = true
    return self
  end
  local previous = self.previous
  if previous and not previous.closed then
    self.previous, self.previous_grid = nil, nil
    owners[self.buf] = previous
    self:close()
    return previous
  end
  self:close()
end

function View:fail(err)
  if not self:current() then
    self:close()
    return
  end
  self.error = tostring(err)
  self:close()
  if self.request.on_error then
    self.request.on_error(self.error)
  elseif
    api.nvim_buf_is_valid(self.buf)
    and api.nvim_win_is_valid(self.win)
    and api.nvim_win_get_buf(self.win) == self.buf
  then
    local writable, modified = vim.bo[self.buf].modifiable, vim.bo[self.buf].modified
    vim.bo[self.buf].modifiable = true
    api.nvim_buf_set_lines(self.buf, 0, -1, false, { "Image preview: " .. self.error:gsub("[\r\n]", " ") })
    vim.bo[self.buf].modified, vim.bo[self.buf].modifiable = modified, writable
  end
end
function View:_start()
  if not self:current() then
    self:close()
    return
  end
  self:release(true)
  self.view_width, self.view_height = self:viewport()
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  self.session = require("image_tools.render.session").new(self:dependency("image"), self.transfer)
  local session = self.session
  local options = vim.tbl_extend("force", {}, self.options, {
    page = self.request.page or self.options.page,
    render_scale = self.request.render_scale or self.options.render_scale,
  })
  session:start(self.path, options, {
    current = function()
      return self.session == session and self:current()
    end,
    stale = function()
      if self.session == session then
        self:close()
      end
    end,
    error = function(err)
      if self.session == session then
        self:fail(err)
      end
    end,
    size = function(image)
      self.view_width, self.view_height = self:viewport()
      return require("image_tools.render.geometry").fit(
        self.request.display_size or image,
        terminal.cell_size(self.options.cell_size),
        math.min(self.view_width, protocol.max_cells),
        math.min(self.view_height, protocol.max_cells),
        self.request.upscale ~= false
      )
    end,
    draw = function(entry, width, height)
      if
        not self:paint(function()
          require("image_tools.render.placeholder").draw(
            self,
            ns,
            "ImageToolsEmbedded_",
            entry,
            width,
            height,
            protocol,
            nil,
            self.view_height
          )
          self.grid = api.nvim_buf_get_lines(self.buf, 0, -1, false)
        end)
      then
        self:close()
      else
        local previous = self.previous
        self.previous, self.previous_grid = nil, nil
        if previous and not previous.closed then
          vim.cmd.redraw()
          previous:close()
        end
      end
    end,
  })
end
function View:start()
  local ok, err = pcall(self._start, self)
  if not ok then
    self:fail(err)
  end
end

function View:resize()
  if self.retained then
    return
  end
  if not self:current() then
    self:close()
    return
  end
  local width, height = self:viewport()
  if width == self.view_width and height == self.view_height then
    return
  end
  -- Pending preparation will size against the latest geometry on completion.
  if self.session and self.session.stage ~= "ready" then
    return
  end
  self:start()
end
function M.new(request, options, dependencies)
  if type(request) ~= "table" or type(request.path) ~= "string" or request.path == "" then
    return nil, "render requires a path, scratch buffer and window"
  end
  if request.display_size then
    for _, name in ipairs({ "width", "height" }) do
      local value = type(request.display_size) == "table" and request.display_size[name]
      if type(value) ~= "number" or value ~= value or value <= 0 or value >= math.huge then
        return nil, "display_size must contain positive finite width and height"
      end
    end
  end
  for _, name in ipairs({ "is_valid", "paint", "on_error" }) do
    if request[name] ~= nil and type(request[name]) ~= "function" then
      return nil, name .. " must be a function"
    end
  end
  if request.page ~= nil and (type(request.page) ~= "number" or request.page < 1 or request.page % 1 ~= 0) then
    return nil, "page must be a positive integer"
  end
  if request.render_scale ~= nil then
    local scale = request.render_scale
    if type(scale) ~= "number" or scale ~= scale or scale < 1 or scale > 8 then
      return nil, "render_scale must be a finite number between 1 and 8"
    end
  end
  if request.upscale ~= nil and type(request.upscale) ~= "boolean" then
    return nil, "upscale must be boolean"
  end
  local buf, win = request.buf, request.win
  if
    type(buf) ~= "number"
    or not api.nvim_buf_is_valid(buf)
    or vim.bo[buf].buftype ~= "nofile"
    or type(win) ~= "number"
    or not api.nvim_win_is_valid(win)
    or api.nvim_win_get_buf(win) ~= buf
  then
    return nil, "render target must be a live window showing the supplied nofile buffer"
  end
  if not require("image_tools.media.formats").supported(request.path) then
    return nil, "Unsupported image format"
  end
  local terminal = dependencies.terminal or require("image_tools.terminal")
  local supported, reason = terminal.supports(options)
  if not supported then
    return nil, reason
  end
  local previous = request.previous
  if
    not (
      getmetatable(previous) == View
      and previous.retained
      and not previous.closed
      and previous.buf == buf
      and previous.win == win
      and owners[buf] == previous
    )
  then
    previous = nil
  end
  if owners[buf] and owners[buf] ~= previous then
    owners[buf]:close()
  end
  local self = setmetatable({
    request = request,
    options = options,
    dependencies = dependencies,
    path = vim.fs.normalize(vim.fn.fnamemodify(request.path, ":p")),
    buf = buf,
    win = win,
    previous = previous,
    previous_grid = previous and previous.grid,
    saved_options = previous and vim.deepcopy(previous.saved_options) or {},
  }, View)
  self.transfer = require("image_tools.terminal.transfer").new(options, dependencies)
  owners[buf] = self
  for name, value in pairs(window_options) do
    if not previous then
      self.saved_options[name] = vim.wo[win][name]
    end
    vim.wo[win][name] = value
  end
  serial = serial + 1
  self.group = api.nvim_create_augroup("ImageToolsEmbedded" .. buf .. "_" .. serial, { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    pattern = tostring(win),
    callback = function()
      if owners[buf] == self then
        self:close()
      end
    end,
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufWinLeave" }, {
    group = self.group,
    buffer = buf,
    callback = function()
      if owners[buf] == self then
        self:close()
      end
    end,
  })
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.group,
    callback = function()
      if self.resize_pending then
        return
      end
      self.resize_pending = true
      vim.schedule(function()
        self.resize_pending = false
        self:resize()
      end)
    end,
  })
  api.nvim_create_autocmd({ "VimLeavePre", "VimSuspend" }, {
    group = self.group,
    callback = function()
      if owners[buf] == self then
        self:close()
      end
    end,
  })
  vim.schedule(function()
    self:start()
  end)
  return self
end
return M
