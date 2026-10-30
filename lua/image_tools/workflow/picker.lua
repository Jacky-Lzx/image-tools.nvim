-- Module: image_tools.workflow.picker
--
-- Purpose:
--   Adapt existing Snacks preview panes to independent
--   image rendering.
--
-- Architecture:
--   Render image items through render/session and
--   shared transfer resources; non-image items use Snacks file preview.
--
-- Ownership:
--   Own picker-specific renderer state, wrapped callbacks and event groups,
--   plus a weak registry for cleanup. Selection changes invalidate pending
--   work; closing releases placements. The import chooser lives in workflow/selection.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  image = "image_tools.media",
  protocol = "image_tools.terminal.protocol",
}

local M = {}
---@class ImageToolsPickerState: ImageToolsDrawState
---@field buf integer Existing Snacks preview buffer.
---@field win integer Existing Snacks preview window; the renderer does not create it.
---@field item table Selected item identity used to reject late results.
---@field view_width integer Current preview viewport columns.
---@field view_height integer Current preview viewport rows.
---@field top? integer Top alignment offset, set to zero on draw.
---@field left? integer Left alignment offset, set to zero on draw.
---@field render? ImageToolsRenderSession Owned media/placement session.
---@class ImageToolsPickerRenderer
---@field picker table Snacks picker whose pane and lifecycle callbacks are wrapped.
---@field opts ImageToolsOptions Runtime transport/render settings.
---@field dependencies table<string, table> Logical dependency overrides.
---@field transfer ImageToolsTransfer View manager over the Runtime shared pixel pool.
---@field state? ImageToolsPickerState Pending/visible selected image.
---@field group? integer Renderer autocmd group; nil after destruction.
---@field resize_pending? boolean Coalesced viewport refresh.
---@field previous_close? function Original picker close callback restored when still owned.
---@field previous_change? function Original picker change callback restored when still owned.
---@field on_close? function Installed close wrapper.
---@field on_change? function Installed selection wrapper.
local Renderer = {}
Renderer.__index = Renderer
local serial = 0
local live = setmetatable({}, { __mode = "k" })
local ns = vim.api.nvim_create_namespace("image_tools.picker")

-- Release the current image session/highlight and clear only the renderer placeholder content.
---@return nil
function Renderer:close()
  local state = self.state
  self.state = nil
  if not state then
    return
  end
  if state.render then
    state.render:close()
  end
  require("image_tools.render.placeholder").clear(state)
  if vim.api.nvim_buf_is_valid(state.buf) then
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, ns, 0, -1, { limit = 1 })
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
    if state.id and #marks > 0 then
      local modifiable = vim.bo[state.buf].modifiable
      vim.bo[state.buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
      vim.bo[state.buf].modifiable = modifiable
    end
  end
end

-- Close rendering, release leases, restore still-owned picker callbacks and remove
-- handlers/registry ownership.
---@return nil
function Renderer:destroy()
  self:close()
  self.transfer:clear()
  if self.picker.opts.on_close == self.on_close then
    self.picker.opts.on_close = self.previous_close
  end
  if self.picker.opts.on_change == self.on_change then
    self.picker.opts.on_change = self.previous_change
  end
  live[self] = nil
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
  if self.picker._image_tools_preview == self then
    self.picker._image_tools_preview = nil
  end
end

-- Snapshot the weak live-renderer registry and destroy every tracked renderer.
---@return nil
function M.clear_all()
  local all = {}
  for renderer in pairs(live) do
    all[#all + 1] = renderer
  end
  for _, renderer in ipairs(all) do
    renderer:destroy()
  end
end

-- Create an independent renderer over a Snacks-owned preview pane and wrap its lifecycle
-- callbacks.
---@param picker table Live Snacks picker.
---@param opts ImageToolsOptions Runtime render/transport options.
---@param dependencies? table<string, table> May include shared pixel_pool.
---@return ImageToolsPickerRenderer renderer
function M.new(picker, opts, dependencies)
  serial = serial + 1
  local self = setmetatable({ picker = picker, opts = opts, dependencies = dependencies or {} }, Renderer)
  self.transfer = require("image_tools.terminal.transfer").new(opts, self.dependencies)
  live[self] = true
  self.group = vim.api.nvim_create_augroup("image_tools.picker." .. serial, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(event)
      if self.state and self.state.win == tonumber(event.match) then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.group,
    callback = function()
      local state = self.state
      if not state or self.resize_pending then
        return
      end
      self.resize_pending = true
      vim.schedule(function()
        self.resize_pending = false
        if
          not self.group
          or self.state ~= state
          or self.picker.closed
          or not vim.api.nvim_win_is_valid(state.win)
          or not vim.api.nvim_buf_is_valid(state.buf)
          or vim.api.nvim_win_get_buf(state.win) ~= state.buf
          or self.picker.preview.item ~= state.item
        then
          return
        end
        local width, height = self:viewport(state.win)
        if width ~= state.view_width or height ~= state.view_height then
          self.picker.preview:show(self.picker, { force = true })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.group,
    callback = function(event)
      if self.state and self.state.buf == event.buf then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimSuspend" }, {
    group = self.group,
    callback = function()
      self:destroy()
    end,
  })
  local on_close, on_change = picker.opts.on_close, picker.opts.on_change
  self.previous_close, self.previous_change = on_close, on_change
  self.on_close = function(...)
    self:destroy()
    if on_close then
      on_close(...)
    end
  end
  self.on_change = function(p, item)
    if self.state and self.state.item ~= item then
      self:close()
    end
    if on_change then
      on_change(p, item)
    end
  end
  picker.opts.on_close, picker.opts.on_change = self.on_close, self.on_change
  return self
end

-- Resolve an injected logical dependency first, then load the default subsystem module.
---@param name string Logical key such as terminal, protocol, image or pdf.
---@return table module
function Renderer:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Compute preview text columns after gutters and available pane rows.
---@param win integer Live Snacks preview window.
---@return integer width
---@return integer height
function Renderer:viewport(win)
  local info = vim.fn.getwininfo(win)[1] or {}
  return math.max(1, vim.api.nvim_win_get_width(win) - (info.textoff or 0)), vim.api.nvim_win_get_height(win)
end

-- Reset the existing pane and prepare/place the selected source with item/window authority and
-- viewport upscaling.
---@param ctx table Snacks preview context owning picker, preview, item, buffer and window.
---@param path string Supported local image path.
---@return nil
function Renderer:show(ctx, path)
  self:close()
  ctx.preview:reset()
  ctx.preview:minimal()
  ctx.preview:set_title(vim.fs.basename(path))
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local supported, reason = terminal.supports(self.opts)
  if not supported then
    ctx.preview:notify(reason, "warn", { item = false })
    return
  end
  local view_width, view_height = self:viewport(ctx.win)
  ---@type ImageToolsPickerState
  local state = { buf = ctx.buf, win = ctx.win, item = ctx.item, view_width = view_width, view_height = view_height }
  self.state = state
  -- Reject completion after selection, pane ownership or picker lifetime changes.
  ---@return boolean valid
  local function current()
    return self.state == state
      and not ctx.picker.closed
      and ctx.preview.item == state.item
      and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_buf_is_valid(state.buf)
      and vim.api.nvim_win_get_buf(state.win) == state.buf
  end

  -- Release image state before presenting the failure through Snacks preview notifications.
  ---@param err string Preparation/placement/drawing error.
  ---@return nil
  local function fail(err)
    self:close()
    ctx.preview:notify(err, "error", { item = false })
  end
  state.render = require("image_tools.render.session").new(self:dependency("image"), self.transfer)
  state.render:start(path, self.opts, {
    current = current,
    -- A late result may close only its own state, never a newer replacement request.
    ---@return nil
    stale = function()
      if self.state == state then
        self:close()
      end
    end,
    error = fail,
    -- Compute cells after preparation using the current owner/pane geometry.
    ---@param image ImageToolsImage
    ---@return integer width
    ---@return integer height
    size = function(image)
      state.view_width, state.view_height = self:viewport(state.win)
      return require("image_tools.render.geometry").fit(
        image,
        terminal.cell_size(self.opts.cell_size),
        math.min(state.view_width, protocol.max_cells),
        math.min(state.view_height, protocol.max_cells),
        true
      )
    end,
    -- Materialize placeholders only after the terminal acknowledges this independent placement.
    ---@param entry ImageToolsPlacement
    ---@param width integer Terminal columns.
    ---@param height integer Terminal rows.
    ---@return nil
    draw = function(entry, width, height)
      ctx.preview:wo({ wrap = false, conceallevel = 0, list = false, spell = false, winblend = 0 })
      state.top, state.left = 0, 0
      require("image_tools.render.placeholder").draw(
        state,
        ns,
        "ImageToolsPicker_",
        entry,
        width,
        height,
        protocol,
        function(lines)
          ctx.preview:set_lines(lines)
        end,
        state.view_height
      )
    end,
  })
end

-- Public custom previewer: uses picker lifecycle, not cursor-line ownership.
-- Render supported images independently; close stale image state and delegate other items to
-- Snacks file preview.
---@param ctx table Snacks preview callback context.
---@param opts ImageToolsOptions Runtime settings.
---@param dependencies? table<string, table> Shared pool and logical overrides.
---@return nil
function M.preview(ctx, opts, dependencies)
  local path = Snacks.picker.util.path(ctx.item)
  if path and require("image_tools.media").supported(path) then
    local renderer = ctx.picker._image_tools_preview
    if not renderer then
      renderer = M.new(ctx.picker, opts, dependencies)
      ctx.picker._image_tools_preview = renderer
    end
    renderer:show(ctx, path)
  else
    if ctx.picker._image_tools_preview then
      ctx.picker._image_tools_preview:close()
    end
    Snacks.picker.preview.file(ctx)
  end
end

return M
