-- Module: image_tools.render.buffer
--
-- Purpose:
--   Provide read-only named image/PDF buffers and their per-window viewers.
--
-- Architecture:
--   Install file interception, manage PDF metadata via media/pdf and delegate
--   drawing to render/canvas. Synchronize visible regular windows, source
--   revisions, page changes and viewer errors.
--
-- Ownership:
--   Own buffer metadata, window views, saved options and handlers. PDF page
--   state is shared per buffer; canvases have independent placements and are
--   cleaned up on hide, teardown or suspension.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  pdf = "image_tools.media.pdf",
}

---@class ImageToolsBufferMetadata
---@field path string Original source path preserved as the named buffer identity.
---@field pdf boolean Whether page metadata is required.
---@field page integer One-based selection shared by every split of this buffer.
---@field pages? integer PDF page count after metadata succeeds.
---@field generation integer Incremented on reload/page change to invalidate old canvases.
---@field key? string Last validated source revision.
---@field error? string User-readable source/metadata/render failure.
---@field cancel_info? ImageToolsCancel Pending pdfinfo operation.
---@class ImageToolsBufferView
---@field buf integer File-viewer buffer displayed by this owner.
---@field saved table<string, any> Previous owner window options restored on release.
---@field canvas ImageToolsCanvas Per-window render controller.
---@field failed? integer Generation whose rendering failed; avoids repeated attempts until refresh.
---@class ImageToolsBuffers
---@field opts ImageToolsOptions Runtime settings and automatic format list.
---@field dependencies table<string, table> PDF/media overrides.
---@field buffers table<integer, ImageToolsBufferMetadata> Source/page metadata indexed by buffer id.
---@field views table<integer, ImageToolsBufferView> Independent views indexed by regular window id.
---@field group? integer Owned file-buffer autocmd group.
---@field pending? boolean Coalesced sync request.
---@field paused? boolean Cache clearing/suspension pauses canvases until explicit resume/entry/reload.
local M = {}
M.__index = M
local window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = false,
  list = false,
  spell = false,
  conceallevel = 0,
  cursorline = false,
}

-- Create empty buffer/view ownership tables; install interception only during setup.
---@param opts ImageToolsOptions Runtime settings.
---@param dependencies? table<string, table> Logical dependency overrides.
---@return ImageToolsBuffers buffers
function M.new(opts, dependencies)
  return setmetatable({ opts = opts, dependencies = dependencies or {}, buffers = {}, views = {} }, M)
end

-- Resolve an injected logical dependency first, then load the default subsystem module.
---@param name string Logical key such as terminal, protocol, image or pdf.
---@return table module
function M:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Rewrite the filename/page/error header, then restore readonly/nonmodifiable/unmodified viewer
-- flags.
---@param buf integer Attached file-viewer buffer.
---@return nil
function M:header(buf)
  local meta = self.buffers[buf]
  if not meta or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local line = vim.fs.basename(meta.path):gsub("[\r\n]", " ")
  if meta.pdf then
    line = line .. "  " .. meta.page .. " / " .. (meta.pages or "?")
  end
  local keys = self.opts.buffer.keymaps
  if keys == nil then
    keys = require("image_tools.defaults").buffer.keymaps
  end
  for _, action in ipairs({ "reload", "info", "zoom_in", "zoom_out", "fit", "native", "next_page", "previous_page" }) do
    if keys and keys[action] and (meta.pdf or action ~= "next_page" and action ~= "previous_page") then
      line = line .. "   " .. keys[action] .. " " .. action:gsub("_", " ")
    end
  end
  local lines = { line }
  if meta.error then
    vim.list_extend(lines, vim.split(meta.error, "\n", { plain = true }))
  end
  vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].modified, vim.bo[buf].readonly = false, false, true
end

-- Remove window ownership, destroy its canvas and restore options unchanged by newer filetype
-- hooks.
---@param win integer Owner window id.
---@return nil
function M:drop_view(win)
  local view = self.views[win]
  if not view then
    return
  end
  self.views[win] = nil
  view.canvas:destroy()
  if vim.api.nvim_win_is_valid(win) then
    for name, value in pairs(view.saved) do
      -- Preserve options already changed by the new buffer's filetype hooks.
      if vim.wo[win][name] == window_options[name] then
        vim.wo[win][name] = value
      end
    end
  end
end

-- Cancel metadata and all window views for a buffer without modifying its original source file.
---@param buf integer Attached buffer id.
---@return nil
function M:release(buf)
  local meta = self.buffers[buf]
  self.buffers[buf] = nil
  if meta and meta.cancel_info then
    meta.cancel_info()
  end
  if meta and vim.api.nvim_buf_is_valid(buf) then
    for _, owned in ipairs(meta.mappings or {}) do
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if mapping.callback == owned.callback then
          pcall(vim.api.nvim_buf_del_keymap, buf, "n", owned.key)
        end
      end
    end
  end
  for win, view in pairs(vim.tbl_extend("force", {}, self.views)) do
    if view.buf == buf then
      self:drop_view(win)
    end
  end
end

-- Pause canvases and destroy their placements; retain buffer metadata for later resume.
---@return nil
function M:clear_cache()
  self.paused = true
  for _, view in pairs(self.views) do
    view.canvas:destroy()
    view.failed = nil
  end
end

-- Remove file-buffer handlers and release every owned view/metadata request.
---@return nil
function M:destroy()
  if self.group then
    vim.api.nvim_del_augroup_by_id(self.group)
    self.group = nil
  end
  for win in pairs(vim.tbl_extend("force", {}, self.views)) do
    self:drop_view(win)
  end
  for buf in pairs(vim.tbl_extend("force", {}, self.buffers)) do
    self:release(buf)
  end
end

-- Coalesce a sync on the main event loop only while handlers remain installed.
---@return nil
function M:schedule()
  if self.pending or not self.group then
    return
  end
  self.pending = true
  vim.schedule(function()
    self.pending = false
    if self.group then
      self:sync()
    end
  end)
end

-- Invalidate the current generation, refresh source checks and asynchronously restart PDF
-- metadata.
---@param buf integer Attached buffer id.
---@return boolean accepted Metadata/rendering errors may be reported later in the header.
---@return string? error
function M:reload(buf)
  self.paused = false
  local meta = self.buffers[buf]
  if not meta then
    return false, "Current buffer is not an image/PDF preview"
  end

  if meta.cancel_info then
    meta.cancel_info()
    meta.cancel_info = nil
  end

  meta.generation, meta.error = meta.generation + 1, nil

  local stat = vim.uv.fs_stat(meta.path)
  if not stat or stat.type ~= "file" then
    meta.error = "File is missing or not a regular file"
  elseif stat.size > self.opts.max_bytes then
    meta.error = "File exceeds max_bytes"
  else
    meta.key = require("image_tools.media").key(meta.path, stat)
  end

  if meta.pdf and not meta.error then
    meta.pages = nil
    local generation = meta.generation
    meta.cancel_info = self:dependency("pdf").info(meta.path, self.opts, function(err, info)
      if self.buffers[buf] ~= meta or meta.generation ~= generation then
        return
      end
      meta.cancel_info = nil
      if err then
        meta.error = err
      else
        meta.pages, meta.key = info.pages, info.key
        meta.page = math.min(meta.page, meta.pages)
      end

      self:header(buf)
      self:schedule()
    end)
  end

  self:header(buf)
  self:schedule()
  return true
end

-- Select an in-range absolute PDF page and invalidate canvas generation only when it changes.
---@param page integer? One-based requested page.
---@param buf? integer Target buffer; defaults to the current buffer.
---@return boolean accepted
---@return string? error
function M:page(page, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local meta = self.buffers[buf]

  if not meta or not meta.pdf then
    return false, "Current buffer is not a PDF preview"
  end

  if not meta.pages then
    return false, meta.error or "PDF metadata is still loading"
  end

  if type(page) ~= "number" or page % 1 ~= 0 or page < 1 or page > meta.pages then
    return false, "PDF page must be between 1 and " .. meta.pages
  end

  if page ~= meta.page then
    meta.page, meta.error, meta.generation = page, nil, meta.generation + 1
    self:header(buf)
    self:schedule()
  end

  return true
end

-- Clamp signed relative page movement to the loaded PDF bounds.
---@param delta integer Signed offset.
---@param buf? integer Target buffer; defaults to current.
---@return boolean accepted
---@return string? error
function M:step(delta, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local meta = self.buffers[buf]
  if not meta or not meta.pages then
    return false, "PDF metadata is unavailable"
  end
  return self:page(math.max(1, math.min(meta.pages, meta.page + delta)), buf)
end

-- Convert a named buffer into a protected viewer, install local mappings and start metadata
-- refresh.
---@param buf integer Source buffer to own.
---@param path string Normalized original source path.
---@return nil
function M:attach(buf, path)
  if self.buffers[buf] then
    self:release(buf)
  end

  ---@type ImageToolsBufferMetadata
  local meta = { path = path, pdf = path:lower():sub(-#".pdf") == ".pdf", page = 1, generation = 0 }
  self.buffers[buf] = meta
  vim.b[buf].image_tools_view = true
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "hide"
  vim.bo[buf].swapfile, vim.bo[buf].modeline, vim.bo[buf].buflisted = false, false, true
  vim.bo[buf].undolevels, vim.bo[buf].readonly = -1, true
  self:header(buf)
  vim.bo[buf].filetype = "image_tools"

  -- Record owned mappings so replacement setup can remove them without erasing user overrides.
  meta.mappings = {}
  local keys = self.opts.buffer.keymaps
  if keys == nil then
    keys = require("image_tools.defaults").buffer.keymaps
  end
  local function mapping(action, callback, desc)
    local key = keys and keys[action]
    if not key then
      return
    end
    local normalized = vim.api.nvim_replace_termcodes(key, true, true, true)
    for _, existing in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if vim.api.nvim_replace_termcodes(existing.lhs, true, true, true) == normalized then
        return
      end
    end
    vim.keymap.set("n", key, callback, { buffer = buf, silent = true, desc = desc })
    meta.mappings[#meta.mappings + 1] = { key = key, callback = callback }
  end
  for action, value in pairs({ zoom_in = "in", zoom_out = "out", fit = "fit", native = "native" }) do
    mapping(action, function()
      self:zoom(value)
    end, "Image zoom " .. value)
  end
  for action, delta in pairs({ pan_left = { -5, 0 }, pan_right = { 5, 0 }, pan_up = { 0, -5 }, pan_down = { 0, 5 } }) do
    mapping(action, function()
      self:pan(delta[1] * vim.v.count1, delta[2] * vim.v.count1)
    end, "Pan image")
  end
  mapping("reload", function()
    self:reload(buf)
  end, "Reload image/PDF preview")
  mapping("info", function()
    vim.cmd("ImageInfo")
  end, "Image metadata")
  if meta.pdf then
    mapping("next_page", function()
      self:step(vim.v.count1, buf)
    end, "Next PDF page")
    mapping("previous_page", function()
      self:step(-vim.v.count1, buf)
    end, "Previous PDF page")
  end

  self:reload(buf)
end

-- Reconcile visible regular windows, source changes, page generations and viewport geometry;
-- release hidden ownership.
---@return nil
function M:sync()
  if self.paused then
    return
  end

  local visible, visible_buffers = {}, {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local meta = self.buffers[buf]

      if meta and vim.api.nvim_win_get_config(win).relative == "" then
        visible[win], visible_buffers[buf] = true, true
        if vim.api.nvim_buf_get_name(buf) ~= meta.path then
          meta.error = "Preview buffer was renamed; reopen the image/PDF"
          self:header(buf)
        end

        local stat = vim.uv.fs_stat(meta.path)
        if
          stat and (not meta.key or require("image_tools.media").key(meta.path, stat) ~= meta.key)
          or not stat and not meta.error
        then
          self:reload(buf)
        end
        if meta.pdf and not meta.pages and not meta.cancel_info and not meta.error then
          self:reload(buf)
        end

        ---@type ImageToolsBufferView?
        local view = self.views[win]
        if view and view.buf ~= buf then
          self:drop_view(win)
          view = nil
        end
        if not view then
          local saved = {}
          for name, value in pairs(window_options) do
            saved[name], vim.wo[win][name] = vim.wo[win][name], value
          end
          view = {
            buf = buf,
            saved = saved,
            viewport = { zoom = "fit", x = 0, y = 0 },
            canvas = require("image_tools.render.canvas").new(self.opts, self.dependencies),
          }
          self.views[win] = view
        end

        if meta.error or (meta.pdf and not meta.pages) then
          view.canvas:close()
        else
          local width, height, col, row = require("image_tools.render.canvas").viewport(win)
          local state = view.canvas.state

          if
            view.failed ~= meta.generation
            and (
              not state
              or state.generation ~= meta.generation
              or state.page ~= meta.page
              or state.view_width ~= width
              or state.view_height ~= height
              or state.col ~= col
              or state.row ~= row
              or state.win and not vim.api.nvim_win_is_valid(state.win)
            )
          then
            view.canvas:open(meta, buf, win, function(err)
              if self.views[win] ~= view or self.buffers[buf] ~= meta then
                return
              end
              if err then
                view.failed = meta.generation
                meta.error = err
                self:header(buf)
                self:schedule()
              end
            end, view.viewport)
          end
        end
      end
    end
  end

  for win in pairs(vim.tbl_extend("force", {}, self.views)) do
    if not visible[win] then
      self:drop_view(win)
    end
  end

  for buf, meta in pairs(self.buffers) do
    if not visible_buffers[buf] and meta.cancel_info then
      meta.cancel_info()
      meta.cancel_info = nil
    end
  end
end

-- Change only the current window's viewport; other splits retain their placements.
function M:zoom(value)
  local view = self.views[vim.api.nvim_get_current_win()]
  if not view then
    return false, "Current window is not an image/PDF viewer"
  end
  if value == "in" or value == "out" then
    local current = view.canvas.state and view.canvas.state.zoom_factor or tonumber(view.viewport.zoom) or 1
    value = math.max(0.125, math.min(8, current * (value == "in" and 2 or 0.5)))
  end
  if
    value ~= "fit"
    and value ~= "native"
    and (type(value) ~= "number" or value ~= value or value < 0.125 or value > 8)
  then
    return false, "Zoom must be fit, native, in, out or a factor from 0.125 to 8"
  end
  view.viewport = { zoom = value, x = 0, y = 0 }
  view.failed = nil
  view.canvas:close()
  self:schedule()
  return true
end

function M:pan(x, y)
  if
    type(x) ~= "number"
    or type(y) ~= "number"
    or x ~= x
    or y ~= y
    or math.abs(x) == math.huge
    or math.abs(y) == math.huge
  then
    return false, "Pan offsets must be finite numbers in terminal cells"
  end
  local view = self.views[vim.api.nvim_get_current_win()]
  if not view then
    return false, "Current window is not an image/PDF viewer"
  end
  view.viewport.x = math.max(0, view.viewport.x + math.floor(x))
  view.viewport.y = math.max(0, view.viewport.y + math.floor(y))
  view.failed = nil
  view.canvas:close()
  self:schedule()
  return true
end

-- Open a supported source through a protected buffer, without taking over a modified unowned
-- buffer.
---@param path string Source path, normalized relative to cwd.
---@return boolean accepted True means file viewing was initiated, not that pixels already displayed.
---@return string? error
function M:open(path)
  self.paused = false
  if type(path) ~= "string" or path == "" or not require("image_tools.media").supported(path) then
    return false, "Choose a supported image or PDF file"
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local buf = vim.fn.bufadd(path)
  if vim.api.nvim_buf_is_loaded(buf) then
    if vim.bo[buf].modified and not self.buffers[buf] then
      return false, "Save the source buffer before opening its preview"
    end
    if not self.buffers[buf] then
      self:attach(buf, path)
    end
  else
    vim.api.nvim_create_autocmd("BufReadCmd", {
      group = self.group,
      buffer = buf,
      once = true,
      callback = function()
        self:attach(buf, path)
      end,
    })
  end
  local ok, err = pcall(vim.api.nvim_cmd, { cmd = "edit", args = { path } }, {})
  if not ok then
    return false, tostring(err)
  end
  self:schedule()
  return true
end

-- Snapshot one attached buffer and its currently owned per-window placement statistics.
---@param buf? integer Target buffer; defaults to current.
---@return table? status Nil for an unowned buffer.
function M:status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local meta = self.buffers[buf]
  if not meta then
    return nil
  end
  local views = {}
  for win, view in pairs(self.views) do
    if view.buf == buf then
      views[win] = {
        window = view.canvas.state and view.canvas.state.win,
        page = view.canvas.state and view.canvas.state.page,
        stage = view.canvas.state and view.canvas.state.render and view.canvas.state.render.stage,
        cache = view.canvas.transfer:status(),
        viewport = vim.deepcopy(view.viewport),
        crop = view.canvas.state and vim.deepcopy(view.canvas.state.crop),
        dimensions = view.canvas.state
          and { width = view.canvas.state.image_width, height = view.canvas.state.image_height },
      }
    end
  end
  return { path = meta.path, page = meta.page, pages = meta.pages, error = meta.error, views = views }
end

-- Install optional interception and lifecycle handlers, attach eligible loaded buffers and
-- schedule reconciliation.
---@return nil
function M:setup()
  self.group = vim.api.nvim_create_augroup("image_tools.buffers", { clear = true })
  if self.opts.buffer.enabled then
    local patterns = {}
    for _, extension in ipairs(self.opts.buffer.formats) do
      patterns[#patterns + 1] = "*."
        .. extension:gsub("%a", function(c)
          return "[" .. c:lower() .. c:upper() .. "]"
        end)
    end
    if #patterns > 0 then
      vim.api.nvim_create_autocmd("BufReadCmd", {
        group = self.group,
        pattern = patterns,
        callback = function(event)
          self:attach(event.buf, vim.api.nvim_buf_get_name(event.buf))
        end,
      })
    end
  end
  vim.api.nvim_create_autocmd({
    "BufWinEnter",
    "WinEnter",
    "TabEnter",
    "TabLeave",
    "WinClosed",
    "VimResized",
    "WinResized",
    "FocusGained",
    "BufFilePost",
  }, {
    group = self.group,
    callback = function()
      self:schedule()
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = self.group,
    pattern = "winbar",
    callback = function()
      self:schedule()
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.group,
    callback = function()
      for _, view in pairs(self.views) do
        local state = view.canvas.state
        if state and state.id then
          vim.api.nvim_set_hl(
            0,
            state.highlight,
            require("image_tools.terminal.protocol").highlight(state.id, state.placement_id)
          )
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = self.group,
    callback = function(event)
      self:release(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = self.group,
    callback = function()
      self:destroy()
    end,
  })
  vim.api.nvim_create_autocmd("VimSuspend", {
    group = self.group,
    callback = function()
      self:clear_cache()
      for _, meta in pairs(self.buffers) do
        if meta.cancel_info then
          meta.cancel_info()
          meta.cancel_info = nil
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResume", "BufEnter", "TabEnter" }, {
    group = self.group,
    callback = function()
      self.paused = false
      self:schedule()
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      local extension = path:match("%.([^./]+)$")
      if
        vim.b[buf].image_tools_view
        or self.opts.buffer.enabled
          and extension
          and vim.tbl_contains(self.opts.buffer.formats, extension:lower())
          and not vim.bo[buf].modified
          and vim.bo[buf].buftype == ""
      then
        self:attach(buf, path)
      end
    end
  end
  self:schedule()
end

return M
