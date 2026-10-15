-- Module: image_tools.render.canvas
--
-- Purpose:
--   Draw an image or PDF page in a canvas bound to a file-viewer window.
--
-- Architecture:
--   Use render/session for preparation/placement and geometry/placeholder for
--   drawing. Derive a viewport below the file header, excluding owner gutters,
--   winbar and statusline; allow viewport upscaling.
--
-- Ownership:
--   Own one canvas state and transfer manager. Authority follows the owner
--   buffer/window/tab and page generation; close releases session/window
--   resources without managing document metadata.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  image = "image_tools.media",
  protocol = "image_tools.terminal.protocol",
}

---@class ImageToolsCanvasState: ImageToolsDrawState
---@field owner_buf integer File-viewer buffer.
---@field owner_win integer Regular owner window.
---@field path string Source path.
---@field page integer Selected page; one for ordinary images.
---@field generation integer Captured buffer refresh/page generation.
---@field view_width integer Available owner text columns.
---@field view_height integer Available image rows below the header.
---@field col integer Zero-based relative-window column after gutters.
---@field row integer Zero-based relative-window row below the header.
---@field render? ImageToolsRenderSession Owned preparation/placement session.
---@class ImageToolsCanvas
---@field opts ImageToolsOptions Runtime settings.
---@field dependencies table<string, table> Logical dependency overrides.
---@field transfer ImageToolsTransfer View placement service.
---@field state? ImageToolsCanvasState Pending/visible canvas, absent after close.
local M = {}
M.__index = M
local CANVAS_ZINDEX = 30
local ns = vim.api.nvim_create_namespace("image_tools.canvas")

-- Construct a file-viewer canvas controller with no window or preparation request yet.
---@param opts ImageToolsOptions Runtime settings.
---@param dependencies? table<string, table> May include shared pixel_pool.
---@return ImageToolsCanvas canvas
function M.new(opts, dependencies)
  local self = setmetatable({ opts = opts, dependencies = dependencies or {} }, M)
  self.transfer = require("image_tools.terminal.transfer").new(opts, self.dependencies)
  return self
end

-- Resolve an injected logical dependency first, then load the default subsystem module.
---@param name string Logical key such as terminal, protocol, image or pdf.
---@return table module
function M:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Drop authority before releasing placement, canvas window/buffer and highlight state.
---@return nil
function M:close()
  local state = self.state
  self.state = nil
  if not state then
    return
  end

  if state.render then
    state.render:close()
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end

  require("image_tools.render.placeholder").clear(state)
end

-- Close this canvas and release its view manager leases.
---@return nil
function M:destroy()
  self:close()
  self.transfer:clear()
end

--- Return: width, height , column, row
-- Compute owner text space excluding gutters, winbar/statusline and an available header row.
---@param win integer Live owner window.
---@return integer width Available columns, at least one.
---@return integer height Available image rows, at least one.
---@return integer column Zero-based relative-window column.
---@return integer row Zero-based relative-window row.
function M.viewport(win)
  local info = vim.fn.getwininfo(win)[1] or {}
  -- API height includes winbar; relative="win" starts below it. getwininfo()
  -- reports text height, already excluding winbar, statusline and separators.
  local height = info.height or (vim.api.nvim_win_get_height(win) - (info.winbar or 0))
  local header = height > 1 and 1 or 0
  return math.max(1, vim.api.nvim_win_get_width(win) - (info.textoff or 0)),
    math.max(1, height - header),
    info.textoff or 0,
    header
end

-- Prepare the selected source/page and bind an acknowledged canvas to the owner window and current
-- tab.
---@param meta ImageToolsBufferMetadata Caller-owned source/page/generation metadata.
---@param owner_buf integer File-viewer buffer.
---@param owner_win integer Regular owner window.
---@param callback fun(err: string?) Nil after drawing; errors after resource cleanup.
---@return nil
function M:open(meta, owner_buf, owner_win, callback)
  self:close()

  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local supported, reason = terminal.supports(self.opts)
  if not supported then
    callback(reason)
    return
  end

  local width, height, col, row = M.viewport(owner_win)
  ---@type ImageToolsCanvasState
  local state = {
    owner_buf = owner_buf,
    owner_win = owner_win,
    path = meta.path,
    page = meta.page,
    generation = meta.generation,
    view_width = width,
    view_height = height,
    col = col,
    row = row,
  }
  self.state = state

  -- Validate source/page generation and owner visibility before drawing.
  ---@return boolean valid
  local function current()
    return self.state == state
      and meta.generation == state.generation
      and meta.page == state.page
      and vim.api.nvim_win_is_valid(owner_win)
      and vim.api.nvim_win_get_buf(owner_win) == owner_buf
      and vim.api.nvim_win_get_tabpage(owner_win) == vim.api.nvim_get_current_tabpage()
  end

  -- Close canvas resources before reporting an error to the file-buffer controller.
  ---@param err string Preparation/placement/drawing failure.
  ---@return nil
  local function fail(err)
    self:close()
    callback(err)
  end

  state.render = require("image_tools.render.session").new(self:dependency("image"), self.transfer)
  state.render:start(meta.path, vim.tbl_extend("force", self.opts, { page = meta.page }), {
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
      width, height, col, row = M.viewport(owner_win)
      state.view_width, state.view_height, state.col, state.row = width, height, col, row
      return require("image_tools.render.geometry").fit(
        image,
        terminal.cell_size(self.opts.cell_size),
        math.min(width, protocol.max_cells),
        math.min(height, protocol.max_cells),
        true
      )
    end,
    -- Materialize placeholders only after the terminal acknowledges this independent placement.
    ---@param entry ImageToolsPlacement
    ---@param width integer Terminal columns.
    ---@param height integer Terminal rows.
    ---@return nil
    draw = function(entry, width, height)
      state.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[state.buf].bufhidden, vim.bo[state.buf].filetype = "wipe", "image_tools_canvas"
      vim.bo[state.buf].swapfile = false
      require("image_tools.render.placeholder").draw(state, ns, "ImageToolsCanvas_", entry, width, height, protocol)
      vim.bo[state.buf].modifiable, vim.bo[state.buf].modified = false, false
      state.win = vim.api.nvim_open_win(state.buf, false, {
        relative = "win",
        win = owner_win,
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "none",
        focusable = false,
        zindex = CANVAS_ZINDEX,
      })
      vim.wo[state.win].wrap, vim.wo[state.win].list, vim.wo[state.win].spell = false, false, false
      vim.wo[state.win].winblend, vim.wo[state.win].conceallevel = 0, 0

      callback(nil)
    end,
  })
end

return M
