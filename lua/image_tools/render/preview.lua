-- Module: image_tools.render.preview
--
-- Purpose:
--   Control a nonfocusable floating preview for a file or selected reference.
--
-- Architecture:
--   Compose render/session, geometry, placeholder and a terminal transfer
--   manager. Decide viewport, window position and notifications; the Runtime
--   supplies current-reference selection and refresh events.
--
-- Ownership:
--   Own one preview state and generation. Buffer/window/version/range authority
--   rejects stale work; close releases the session and window, while destroy
--   also clears the transfer manager.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  image = "image_tools.media",
  protocol = "image_tools.terminal.protocol",
}

---@class ImageToolsPreviewState: ImageToolsDrawState
---@field owner_buf integer Document buffer or explicit-preview owner.
---@field owner_win integer Regular window from which preview was requested.
---@field cursor integer[] Captured one-based row and zero-based byte column.
---@field path string Absolute source path.
---@field source_version? string Filesystem revision captured when preparation starts.
---@field image_width? integer Prepared raster width.
---@field image_height? integer Prepared raster height.
---@field changedtick integer Version kept current when edits preserve the source.
---@field automatic boolean Whether notification-silent mode was requested.
---@field reference boolean Whether cursor column/reference selection participates in authority.
---@field reference_range? ImageToolsRange Multiline selected-reference coverage.
---@field formula? string Standalone TeX retained for preparation and reload.
---@field render? ImageToolsRenderSession Owned prepare/placement lifecycle.
---@class ImageToolsPreview
---@field opts ImageToolsOptions Runtime configuration.
---@field dependencies table<string, table> Logical dependency overrides.
---@field generation integer Monotonic close/replacement token.
---@field state? ImageToolsPreviewState Current pending/visible preview; nil after close.
---@field transfer ImageToolsTransfer Shared-pool view placement manager.
---@field last_error? table Most recent failed request, without live resources.
local M = {}
M.__index = M
local SCREEN_MARGIN_CELLS = 4
local BORDER_CELLS = 2 -- One cell on each side of the floating window.
local PREVIEW_ZINDEX = 50
local LASTSTATUS = { MULTIPLE_WINDOWS = 1, ALWAYS = 2, GLOBAL = 3 }
local loading_ns = vim.api.nvim_create_namespace("image_tools.preview_loading")

-- ui-tools draws a one-column scrollbar above previews (zindex 60). Reserve
-- its lane while enabled, including before its deferred refresh creates a bar
-- or when all lines fit, so image/formula previews never jump into that lane.
-- Inspect only loaded modules: previewing must not load an optional UI plugin.
local function right_edge(opts)
  local scrollbar = package.loaded["ui_tools.scrollbar"]
  local padding = math.max(opts.right_padding or 0, scrollbar and scrollbar.enabled and 1 or 0)
  -- Keep room for at least one image column and its border after resizing.
  return math.max(math.min(vim.o.columns, BORDER_CELLS + 1), vim.o.columns - padding)
end

-- Loading hints belong to the request and must disappear on every completion path.
local function clear_loading(state)
  if state.loading_timer then
    if not state.loading_timer:is_closing() then
      state.loading_timer:stop()
      state.loading_timer:close()
    end
    state.loading_timer = nil
  end
  if state.loading_mark and vim.api.nvim_buf_is_valid(state.owner_buf) then
    pcall(vim.api.nvim_buf_del_extmark, state.owner_buf, loading_ns, state.loading_mark)
    state.loading_mark = nil
  end
end

function M:record_error(path, err, stage, state)
  self.last_error = {
    path = path,
    error = tostring(err),
    error_stage = stage,
    format = state and state.formula and "math" or nil,
    width = state and state.image_width,
    height = state and state.image_height,
    timings = state and state.render and state.render:timings(),
  }
end

-- Construct a floating-preview controller and its placement manager without opening a window.
---@param opts ImageToolsOptions Runtime settings.
---@param dependencies? table<string, table> May include a shared pixel_pool.
---@return ImageToolsPreview preview
function M.new(opts, dependencies)
  local self = setmetatable({ opts = opts, dependencies = dependencies or {}, generation = 0 }, M)
  self.transfer = require("image_tools.terminal.transfer").new(opts, self.dependencies)
  return self
end

-- Resolve an injected logical dependency first, then load the default subsystem module.
---@param name string Logical key such as terminal, protocol, image or pdf.
---@return table module
function M:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Retain the existing helper while all renderers depend on geometry directly.
M.fit = require("image_tools.render.geometry").fit

-- Invalidate generation before releasing the session, window, highlights and scratch buffer.
---@return nil
function M:close()
  self.generation = self.generation + 1
  local state = self.state
  self.state = nil
  if not state then
    return
  end
  clear_loading(state)
  if state.render then
    state.render:close()
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  require("image_tools.render.placeholder").clear(state)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  if state.on_close then
    state.on_close()
  end
end

-- Close the view and clear its transfer manager; shared pools retain other managers until Runtime
-- cleanup.
---@return nil
function M:destroy()
  self:close()
  self.transfer:clear()
end

-- Check selected row coverage without requiring one fixed row for multiline LaTeX.
---@param state ImageToolsPreviewState Owner window/captured cursor and optional range.
---@return boolean covered
local function on_reference_row(state)
  local row = vim.api.nvim_win_get_cursor(state.owner_win)[1]
  local range = state.reference_range
  return range and row >= range.start_row and row <= range.end_row or not range and row == state.cursor[1]
end

-- Replace the current request, validate terminal support and asynchronously prepare/place a
-- nonfocusable float.
---@param path string Source path resolved by the Runtime.
---@param options? ImageToolsPreviewOptions Per-request notification and reference authority.
---@return boolean accepted True means started, not necessarily visible yet.
---@return string? error Terminal support rejection.
function M:open(path, options)
  options = options or {}
  self:close()
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local supported, reason = terminal.supports(self.opts)
  if not supported then
    self:record_error(path, reason, "terminal")
    if not options.silent then
      vim.notify(reason, vim.log.levels.WARN, { title = "image-tools" })
    end
    return false, reason
  end
  local generation = self.generation
  local state = {
    owner_buf = vim.api.nvim_get_current_buf(),
    owner_win = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
    path = path,
    automatic = options.silent or false,
    reference = options.reference or false,
    reference_range = options.reference_range,
    formula = options._formula,
    on_close = options._external and options._external.on_close,
  }
  state.changedtick = vim.api.nvim_buf_get_changedtick(state.owner_buf)
  ---@cast state ImageToolsPreviewState
  self.state = state
  state.render = require("image_tools.render.session").new(self:dependency("image"), self.transfer, options._timings)
  local delay = self.opts.preview_loading_delay or 300
  if delay > 0 then
    state.loading_timer = vim.defer_fn(function()
      state.loading_timer = nil
      if self.state == state and vim.api.nvim_buf_is_valid(state.owner_buf) then
        state.loading_mark = vim.api.nvim_buf_set_extmark(state.owner_buf, loading_ns, state.cursor[1] - 1, 0, {
          virt_text = { { state.formula and "Rendering formula…" or "Loading image…", "Comment" } },
          virt_text_pos = "eol",
        })
      end
    end, delay)
  end
  local preparation = state.formula and vim.tbl_extend("force", self.opts, { _formula = state.formula }) or self.opts
  if options._remote_refresh then
    preparation = vim.tbl_extend("force", preparation, { _remote_refresh = true })
  end
  state.render:start(path, preparation, {
    -- Validate generation, owner, text version and current selected cursor/range authority.
    ---@return boolean current
    current = function()
      return self.generation == generation
        and self.state == state
        and vim.api.nvim_win_is_valid(state.owner_win)
        and vim.api.nvim_buf_is_valid(state.owner_buf)
        and vim.api.nvim_get_current_win() == state.owner_win
        and vim.api.nvim_get_current_buf() == state.owner_buf
        and (
          options._external and options._external.is_valid()
          or not options._external
            and vim.api.nvim_buf_get_changedtick(state.owner_buf) == state.changedtick
            and on_reference_row(state)
            and (not state.reference or vim.api.nvim_win_get_cursor(state.owner_win)[2] == state.cursor[2])
        )
    end,
    -- A late result may close only its own state, never a newer replacement request.
    ---@return nil
    stale = function()
      if self.state == state then
        self:close()
      end
    end,
    -- Release the view before notification, honoring silent automatic-preview requests.
    ---@param err string
    ---@return nil
    error = function(err)
      self:record_error(path, err, state.render.error_stage, state)
      if options._external and options._external.on_error then
        options._external.on_error(err)
      end
      self:close()
      if not options._external and not options.silent then
        vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
      end
    end,
    -- Compute cells after preparation using the current owner/pane geometry.
    ---@param image ImageToolsImage
    ---@return integer width
    ---@return integer height
    size = function(image)
      state.image_width, state.image_height = image.width, image.height
      state.source_bytes, state.source_format = image.source_bytes, image.source_format
      return require("image_tools.render.geometry").fit(
        options.display_size or image.display_size or image,
        terminal.cell_size(self.opts.cell_size),
        math.max(1, math.min(self.opts.max_width, protocol.max_cells, right_edge(self.opts) - SCREEN_MARGIN_CELLS)),
        math.max(
          1,
          math.min(self.opts.max_height, protocol.max_cells, vim.o.lines - vim.o.cmdheight - SCREEN_MARGIN_CELLS)
        )
      )
    end,
    -- Materialize placeholders only after the terminal acknowledges this independent placement.
    ---@param entry ImageToolsPlacement
    ---@param width integer Terminal columns.
    ---@param height integer Terminal rows.
    ---@return nil
    draw = function(entry, width, height)
      clear_loading(state)
      state.cursor = vim.api.nvim_win_get_cursor(state.owner_win)
      state.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[state.buf].buftype = "nofile"
      vim.bo[state.buf].bufhidden = "wipe"
      vim.bo[state.buf].swapfile = false
      vim.bo[state.buf].filetype = "image_tools_preview"
      local window = {
        relative = "editor",
        width = width,
        height = height,
        style = "minimal",
        border = self.opts.border,
        focusable = false,
        zindex = PREVIEW_ZINDEX,
        title = options.title or (state.formula and " Formula " or " " .. vim.fs.basename(path) .. " "),
        title_pos = "center",
      }
      if self.opts.position == "bottom_right" then
        local statusline = vim.o.laststatus == LASTSTATUS.ALWAYS
          or vim.o.laststatus == LASTSTATUS.GLOBAL
          or (vim.o.laststatus == LASTSTATUS.MULTIPLE_WINDOWS and vim.fn.winnr("$") > 1)
        window.anchor = "SE"
        window.row = math.max(0, vim.o.lines - vim.o.cmdheight - (statusline and 1 or 0))
        window.col = right_edge(self.opts)
      else
        local position = vim.fn.screenpos(state.owner_win, state.cursor[1], state.cursor[2] + 1)
        window.row = math.max(0, math.min(position.row, vim.o.lines - vim.o.cmdheight - height - BORDER_CELLS))
        window.col = math.max(0, math.min(position.col, right_edge(self.opts) - width - BORDER_CELLS))
      end
      state.win = vim.api.nvim_open_win(state.buf, false, window)
      vim.wo[state.win].wrap = false
      vim.wo[state.win].winblend = 0
      vim.wo[state.win].conceallevel = 0
      vim.wo[state.win].list = false
      vim.wo[state.win].spell = false
      require("image_tools.render.placeholder").draw(
        state,
        vim.api.nvim_create_namespace("image_tools.preview"),
        "ImageTools_",
        entry,
        width,
        height,
        protocol
      )
      vim.bo[state.buf].modifiable = false
      vim.bo[state.buf].modified = false
    end,
  })
  return true
end

return M
