-- Module: image_tools.runtime
--
-- Purpose:
--   Coordinate one editor configuration, its services, commands and event
--   lifecycle.
--
-- Architecture:
--   Compose render controllers, workflow services and a shared terminal pixel
--   pool. Resolve logical dependency keys to subsystem modules, while injected
--   dependencies take priority.
--
-- Ownership:
--   Own handlers, preview authority, pending reference selection and picker
--   renderers. Disposal disables callbacks before delegating resource cleanup
--   to services.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  preview = "image_tools.render.preview",
  buffer = "image_tools.render.buffer",
  disk_cache = "image_tools.media.disk_cache",
  insert = "image_tools.workflow.insert",
  clipboard = "image_tools.workflow.clipboard",
  picker = "image_tools.workflow.picker",
}

---@class ImageToolsPreviewOptions
---@field silent? boolean Suppress preview notifications.
---@field reference? boolean Internal flag for document-reference authority.
---@field reference_range? ImageToolsRange Internal selected reference coverage.
---@field automatic? boolean Internal automatic request; manual calls bypass the delay.
---@field _formula? string Internal standalone TeX source for a selected formula.
---@class ImageToolsReferenceRequest
---@field buf integer Captured buffer id.
---@field win integer Captured window id.
---@field row integer One-based cursor row.
---@field col integer Zero-based byte column.
---@field tick integer Captured changedtick.
---@field range? ImageToolsRange Multiline range that can keep row movement valid.
---@class ImageToolsRuntimeStatus
---@field configured boolean Whether an active undisposed Runtime exists.
---@field auto_preview boolean Current automatic-preview setting; false before setup.
---@field transport "auto"|"file"|"direct" Current policy; auto before setup.
---@field tools? table<string, string> Configured tool executable paths.
---@field cell_size? ImageToolsCellSize Configured fallback cell geometry.
---@field path? string Current floating preview source, including pending preparation.
---@field window? integer Float id; absent until acknowledged pixels are drawn.
---@field buffer? table Current file-viewer metadata and per-window state.
---@field disk_cache? table Configured limits/path, not a live filesystem usage scan.
---@field conversion_queue? ImageToolsQueueStatus Shared process counters and budget.
---@field media? table Shared pending preparation count.
---@field treesitter? ImageToolsSyntaxStatus Global parser counters and current-buffer diagnostics.
---@field terminal_cache? ImageToolsTerminalStatus Runtime-wide acknowledged pixel/placement statistics.
---@class ImageToolsRuntime
---@field options ImageToolsOptions Resolved configuration owned by this instance.
---@field dependencies table<string, table> Logical overrides plus the instance's shared pixel_pool.
---@field disposed boolean Guard that disables callbacks before teardown.
---@field preview? ImageToolsPreview Created on the first accepted floating preview.
---@field buffers ImageToolsBuffers File-buffer controller.
---@field renderers table<table, boolean> Weak-key set of tracked picker renderers.
---@field group? integer Runtime autocmd group installed at start.
---@field commands? string[] Registered command names removed at destruction.
---@field refresh_pending? boolean Coalesced scheduled refresh.
---@field reference_request? ImageToolsReferenceRequest Last selection authority token.
---@field pending_reference? ImageToolsReferenceRequest Current authoritative pending parse.
local Runtime = {}
Runtime.__index = Runtime

-- Keep file interception ready, deferring floating previews and pixels until needed.
---@param options ImageToolsOptions Resolved independent options.
---@param dependencies? table<string, table> Logical service overrides for controlled construction.
---@return ImageToolsRuntime runtime
function Runtime.new(options, dependencies)
  local self = setmetatable({
    options = options,
    dependencies = vim.tbl_extend("force", {}, dependencies or {}),
    disposed = false,
    renderers = setmetatable({}, { __mode = "k" }),
  }, Runtime)
  -- All render controllers share this table. Resolve the pool only when a view
  -- first asks for it, and cache it so later views retain shared ownership.
  setmetatable(self.dependencies, {
    __index = function(deps, name)
      if name == "pixel_pool" then
        local pool = require("image_tools.terminal.pixel_pool").new(options, deps)
        rawset(deps, name, pool)
        return pool
      end
    end,
  })
  self.buffers = self:dependency("buffer").new(options, self.dependencies)
  return self
end

-- Construct the floating controller only for an actual preview request.
---@return ImageToolsPreview preview
function Runtime:ensure_preview()
  if not self.preview then
    self.preview = self:dependency("preview").new(self.options, self.dependencies)
  end
  return self.preview
end

-- Inspect existing pixels without constructing an unused pool or preview.
---@return ImageToolsTerminalStatus? status Absent until a render service exists.
function Runtime:terminal_status()
  local pool = rawget(self.dependencies, "pixel_pool")
  if pool then
    return pool:status()
  end
  return self.preview and self.preview.transfer:status() or nil
end

-- Resolve an injected logical dependency first, then load the default subsystem module.
---@param name string Logical key such as terminal, protocol, image or pdf.
---@return table module
function Runtime:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Wrap a callback so a disposed Runtime cannot respond to old commands or events.
---@param callback function Operation bound to this instance.
---@return function guarded
function Runtime:bind(callback)
  return function(...)
    if not self.disposed then
      return callback(...)
    end
  end
end

-- Coalesce scheduled refreshes and discard them if this Runtime is disposed before delivery.
---@return nil
function Runtime:schedule_refresh()
  if self.disposed or self.refresh_pending then
    return
  end
  self.refresh_pending = true
  vim.schedule(function()
    self.refresh_pending = false
    if not self.disposed then
      self:refresh()
    end
  end)
end

-- Disable callbacks first, remove registered handlers and delegate owned-resource cleanup exactly
-- once.
---@return nil
function Runtime:destroy()
  if self.disposed then
    return
  end

  -- Disable callbacks before closing windows, which can trigger more events.
  self.disposed = true
  for cancel in pairs(self.moves or {}) do
    cancel()
  end
  if self.group then
    vim.api.nvim_del_augroup_by_id(self.group)
    self.group = nil
  end
  for _, name in ipairs(self.commands or {}) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  self.commands = nil

  self:clear_cache()
  self.buffers:destroy()
end

-- Check inclusive row coverage, falling back to the original row for non-range requests.
---@param range? ImageToolsRange Selected reference range.
---@param row integer Current one-based row.
---@param original integer Captured one-based row.
---@return boolean covered
local function covers(range, row, original)
  return range and row >= range.start_row and row <= range.end_row or not range and row == original
end

-- Check the current owner buffer/window and reference row coverage before retaining a preview.
---@param state? ImageToolsPreviewState Current float/preparation state.
---@return boolean? current Nil is allowed when there is no state.
local function on_current_line(state)
  return state
    and state.owner_buf == vim.api.nvim_get_current_buf()
    and state.owner_win == vim.api.nvim_get_current_win()
    and covers(state.reference_range, vim.api.nvim_win_get_cursor(0)[1], state.cursor[1])
end

-- Validate pending parse authority against the current column, owner, text version and range.
---@param request ImageToolsReferenceRequest Pending selection token.
---@return boolean current
local function owns_pending(request)
  local cursor = vim.api.nvim_win_get_cursor(0)
  return request.col == cursor[2]
    and request.buf == vim.api.nvim_get_current_buf()
    and request.win == vim.api.nvim_get_current_win()
    and request.tick == vim.api.nvim_buf_get_changedtick(0)
    and covers(request.range, vim.api.nvim_win_get_cursor(0)[1], request.row)
end

-- Copy reference coverage without retaining syntax backend state.
---@param reference? ImageToolsReference Parsed selection.
---@return ImageToolsRange? range
local function range_of(reference)
  if reference and reference.start_row and reference.end_row then
    return {
      start_row = reference.start_row,
      start_col = reference.start_col,
      end_row = reference.end_row,
      end_col = reference.end_col,
    }
  end
end

-- Invalidate pending reference authority and close only the floating preview.
---@return nil
function Runtime:close()
  self:cancel_auto_preview()
  self.reference_request = nil
  self.pending_reference = nil
  if self.preview then
    self.preview:close()
  end
end

-- Invalidate reference work, pause file canvases, destroy picker renderers and clear shared
-- terminal pixels.
---@return nil
function Runtime:clear_cache()
  self:cancel_auto_preview()
  self.reference_request, self.pending_reference = nil, nil
  if self.buffers then
    self.buffers:clear_cache()
  end
  local renderers = self.renderers
  self.renderers = setmetatable({}, { __mode = "k" })
  for renderer in pairs(renderers) do
    renderer:destroy()
  end
  if self.preview then
    self.preview:destroy()
  end
  local pool = rawget(self.dependencies, "pixel_pool")
  if pool then
    pool:clear()
  end
end

-- Schedule an independent unused-disk-file cleanup.
---@param callback? fun(status: ImageToolsDiskCleanupStatus) Completion status.
---@return nil
function Runtime:clear_disk_cache(callback)
  return self:dependency("disk_cache").clear(self.options, callback)
end

-- Start a floating preview of an explicit path resolved relative to cwd.
---@param path string Image path.
---@param opts? ImageToolsPreviewOptions Notification/reference authority options.
---@return boolean accepted Request accepted; successful display is asynchronous.
---@return string? error
function Runtime:open_preview(path, opts)
  self:cancel_auto_preview()
  if type(path) ~= "string" or path == "" then
    return false, "An image path is required"
  end
  if not (opts and opts._formula) then
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  end
  local stat = vim.uv.fs_stat(path)
  local version = stat and require("image_tools.media.file_version").key(path, stat)
  local ok, err = self:ensure_preview():open(path, opts)
  if self.preview and self.preview.state then
    self.preview.state.source_version = version
  end
  return ok, err
end

-- Import/reference one file or a batch at a captured document position; nil paths prompt for a
-- file.
---@param paths? string|string[] Source paths.
---@param opts? ImageToolsInsertOptions Per-operation insertion overrides.
---@param callback? ImageToolsInsertCallback Reports completion or cancellation.
---@return ImageToolsCancel cancel
function Runtime:insert(paths, opts, callback)
  local insertion = self:dependency("insert")
  opts = vim.tbl_extend(
    "force",
    self.options.insert,
    { max_bytes = self.options.max_bytes, reference_root = self.options.root },
    opts or {}
  )
  if paths then
    return insertion.files(type(paths) == "string" and { paths } or paths, opts, callback)
  end
  local context = opts.context or insertion.capture(opts)
  opts.context = context
  local cancelled, cancel_import = false, nil
  -- Cancel the file prompt/import without redirecting its captured document context.
  ---@return nil
  local function cancel()
    if cancelled then
      return
    end
    cancelled = true
    if cancel_import then
      cancel_import()
    else
      insertion.release(context)
    end
  end
  vim.ui.input({ prompt = "Image file: ", completion = "file" }, function(path)
    if cancelled then
      return
    end
    if not path or path == "" then
      cancel()
      if callback then
        callback("Cancelled")
      end
      return
    end
    cancel_import = insertion.files({ path }, opts, callback)
  end)
  return cancel
end

-- Start a clipboard import using a captured document context.
---@param opts? ImageToolsInsertOptions Insertion and clipboard options.
---@param callback? ImageToolsInsertCallback Reports completion or cancellation.
---@return ImageToolsCancel cancel
function Runtime:paste(opts, callback)
  local insertion = vim.tbl_extend("force", self.options.insert, {
    max_bytes = self.options.max_bytes,
    max_dimension = self.options.max_dimension,
    max_pixels = self.options.max_pixels,
    magick = self.options.magick,
    convert_timeout = self.options.convert_timeout,
    reference_root = self.options.root,
  }, opts or {})
  return self:dependency("clipboard").paste(insertion, callback)
end

-- Provide the custom Snacks preview callback, with ordinary file preview fallback.
---@param ctx table Snacks preview context.
---@return nil
function Runtime:snacks_preview(ctx)
  local result = self:dependency("picker").preview(ctx, self.options, self.dependencies)
  local renderer = ctx.picker._image_tools_preview
  if renderer then
    self.renderers[renderer] = true
  end
  return result
end

-- Open the optional Snacks picker and import confirmed selections at the original extmark.
---@param opts? table insert and picker override tables.
---@param callback? ImageToolsInsertCallback Reports import results or unconfirmed cancellation.
---@return table? picker Nil when picker construction fails.
function Runtime:pick(opts, callback)
  opts = opts or {}
  local insertion = vim.tbl_extend(
    "force",
    self.options.insert,
    { max_bytes = self.options.max_bytes, reference_root = self.options.root },
    opts.insert or {}
  )
  return self:dependency("picker").pick(insertion, opts.picker, function(ctx)
    if not self.disposed then
      return self:snacks_preview(ctx)
    end
  end, callback)
end

-- Open an explicit read-only image/PDF file buffer; errors during rendering appear in the buffer.
---@param path string Source file path.
---@return boolean accepted
---@return string? error
function Runtime:open(path)
  return self.buffers:open(path)
end

-- Select an absolute PDF page in the current file-viewer buffer.
---@param page integer? One-based page; out-of-range values are rejected.
---@return boolean accepted
---@return string? error
function Runtime:page(page)
  return self.buffers:page(page)
end

-- Move within the current PDF, clamping at the first and last pages.
---@param delta? integer Signed page offset; defaults to one.
---@return boolean accepted
---@return string? error
function Runtime:next_page(delta)
  return self.buffers:step(delta or 1)
end

-- Inspect a captured document or project and its import directories; never mutate files.
function Runtime:check_assets(opts, callback)
  return require("image_tools.workflow.assets").check(vim.tbl_deep_extend("force", self.options, opts or {}), callback)
end

function Runtime:move(source, target, opts, callback)
  self.moves = self.moves or {}
  local cancel
  cancel = require("image_tools.workflow.move").move(
    source,
    target,
    vim.tbl_deep_extend("force", self.options, opts or {}),
    function(err, plan)
      if cancel then
        self.moves[cancel] = nil
      end
      if not self.disposed then
        if not err then
          self:close()
          self:schedule_refresh()
        end
        if callback then
          callback(err, plan)
        elseif err ~= "Cancelled" then
          vim.notify(
            err or string.format("Moved image; updated %d document(s). Save modified buffers with :wall", #plan.changes),
            err and vim.log.levels.ERROR or vim.log.levels.INFO
          )
        end
      end
    end
  )
  self.moves[cancel] = true
  return cancel
end

function Runtime:zoom(value)
  return self.buffers:zoom(value)
end

function Runtime:pan(x, y)
  return self.buffers:pan(x, y)
end

-- Force source/metadata refresh in the current image/PDF viewer.
---@return boolean accepted
---@return string? error
function Runtime:reload()
  if self.buffers:status() then
    return self.buffers:reload(vim.api.nvim_get_current_buf())
  end
  local state = self.preview and self.preview.state
  if state and on_current_line(state) then
    return self:open_preview(state.path, {
      silent = state.automatic,
      reference = state.reference,
      reference_range = state.reference_range,
      _formula = state.formula,
    })
  end
  return false, "No image/PDF viewer or floating preview to reload"
end

-- Recheck external changes on idle/focus events, outside the cursor-movement hot path.
function Runtime:refresh_source()
  local state = self.preview and self.preview.state
  if not state or not on_current_line(state) then
    return
  end
  local stat = vim.uv.fs_stat(state.path)
  local version = stat and require("image_tools.media.file_version").key(state.path, stat)
  if version ~= state.source_version then
    self:reload()
  end
end

-- Select the cursor reference, falling back to the first covering reference only on a selection
-- miss.
---@param opts? ImageToolsPreviewOptions silent suppresses notifications.
---@return boolean accepted False for errors or an authoritative pending syntax parse.
---@return string? error
function Runtime:hover(opts)
  opts = opts or {}
  if not opts.automatic then
    self:cancel_auto_preview()
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local buf, win, tick =
    vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_buf_get_changedtick(0)
  local pending = self.pending_reference
  if pending and owns_pending(pending) then
    return false, "Tree-sitter parsing is pending"
  end
  local request = { buf = buf, win = win, row = cursor[1], col = cursor[2], tick = tick }
  self.reference_request = request
  local options = vim.tbl_extend("force", self.options, {
    _treesitter_ready = function()
      if not self.disposed and self.reference_request == request and owns_pending(request) then
        self.pending_reference = nil
        self:hover(opts)
      end
    end,
  })
  local document = self:dependency("document")
  local lookup_started = vim.uv.hrtime()
  local path, err, status, reference = document.at_cursor(buf, cursor[1], cursor[2], options)
  if status == "miss" then
    path, err, status, reference = document.at_line(buf, cursor[1], options)
  end
  local timing = { lookup_ms = (vim.uv.hrtime() - lookup_started) / 1e6 }
  request.range = range_of(reference)
  if status == "pending" then
    self:cancel_auto_preview()
    self.pending_reference = request
    if self.preview then
      self.preview:close()
    end
    return false, err
  end
  if not path then
    self:close()
    if not opts.silent then
      vim.notify(err, vim.log.levels.INFO, { title = "image-tools" })
    end
    return false, err
  end
  if self.preview and on_current_line(self.preview.state) and self.preview.state.path == path then
    -- A text edit elsewhere on the same line must not invalidate a pending
    -- conversion when the resolved image source is unchanged.
    self.preview.state.changedtick = vim.api.nvim_buf_get_changedtick(0)
    self.preview.state.reference = true
    self.preview.state.reference_range = request.range
    self.preview.state.cursor = cursor
    return true
  end
  if opts.automatic and self.options.auto_preview and self.options.auto_preview_delay > 0 then
    local delayed = self.delayed_reference
    if delayed and delayed.path == path and delayed.buf == buf and delayed.win == win then
      delayed.row, delayed.col, delayed.tick, delayed.range = request.row, request.col, tick, request.range
      return true
    end
    self:cancel_auto_preview()
    if self.preview then
      self.preview:close()
    end
    request.path = path
    local delayed_at = vim.uv.hrtime()
    self.delayed_reference = request
    self.auto_preview_timer = vim.defer_fn(function()
      if self.delayed_reference ~= request then
        return
      end
      self.auto_preview_timer = nil
      self.delayed_reference = nil
      if not self.disposed and self.options.auto_preview and owns_pending(request) then
        timing.automatic_delay_ms = (vim.uv.hrtime() - delayed_at) / 1e6
        self:open_preview(
          path,
          vim.tbl_extend("force", opts, {
            reference = true,
            reference_range = request.range,
            _timings = timing,
            _formula = reference and reference.formula,
          })
        )
      end
    end, self.options.auto_preview_delay)
    return true
  end
  return self:open_preview(
    path,
    vim.tbl_extend("force", opts, {
      reference = true,
      reference_range = request.range,
      _timings = timing,
      _formula = reference and reference.formula,
    })
  )
end

-- Drop delayed automatic work without affecting already-started render sessions.
function Runtime:cancel_auto_preview()
  self.delayed_reference = nil
  local timer = self.auto_preview_timer
  self.auto_preview_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

-- Toggle automatic reference preview, close current work and refresh when newly enabled.
---@return boolean enabled
function Runtime:toggle()
  self.options.auto_preview = not self.options.auto_preview
  self:close()
  if self.options.auto_preview then
    self:refresh()
  end
  vim.notify(
    "Automatic image preview " .. (self.options.auto_preview and "enabled" or "disabled"),
    vim.log.levels.INFO,
    { title = "image-tools" }
  )
  return self.options.auto_preview
end

-- Describe the active viewer without starting media work or populating caches.
function Runtime:info()
  local buffer = self.buffers:status()
  local state = self.preview and self.preview.state
  local view = buffer and buffer.views[vim.api.nvim_get_current_win()]
  local path = buffer and buffer.path or state and on_current_line(state) and state.path
  if not path then
    local failure = self.preview and self.preview.last_error
    if failure then
      local failed_stat = vim.uv.fs_stat(failure.path)
      return vim.tbl_extend("force", failure, {
        format = failure.format or require("image_tools.media.formats").extension(failure.path),
        bytes = failed_stat and failed_stat.size,
        stage = "failed",
        ready = false,
        last_error = true,
        terminal_cache = self:terminal_status(),
        disk_cache = self.options.cache,
      })
    end
    return nil, "No active image/PDF viewer or floating preview"
  end
  local dimensions = view and view.dimensions or {}
  local stat = vim.uv.fs_stat(path)
  return {
    path = path,
    format = not buffer and state and state.formula and "math" or require("image_tools.media.formats").extension(path),
    bytes = stat and stat.size,
    width = buffer and dimensions.width or state and state.image_width,
    height = buffer and dimensions.height or state and state.image_height,
    page = buffer and buffer.page or (path:lower():match("%.pdf$") and 1 or nil),
    pages = buffer and buffer.pages,
    error = buffer and buffer.error,
    stage = buffer and (buffer.error and "failed" or view and view.stage or "preparing")
      or state.render and state.render.stage
      or "preparing",
    zoom = view and view.viewport.zoom,
    crop = view and vim.deepcopy(view.crop),
    ready = not not (buffer and view and view.window or not buffer and state and state.win),
    timings = buffer and view and view.timings
      or not buffer and state and state.render and state.render:timings()
      or nil,
    terminal_cache = self:terminal_status(),
    disk_cache = self.options.cache,
  }
end

-- Return service/configuration snapshots without starting a parser or performing disk inspection.
---@return ImageToolsRuntimeStatus status
function Runtime:status()
  local clipboard, clipboard_error = require("image_tools.workflow.clipboard_backend").detect(self.options.insert)
  return {
    clipboard = clipboard and { backend = clipboard.name, executable = clipboard.executable }
      or { error = clipboard_error },
    configured = not self.disposed,
    buffer = self.buffers and self.buffers:status() or nil,
    auto_preview = self.options and self.options.auto_preview or false,
    path = self.preview and self.preview.state and self.preview.state.path or nil,
    window = self.preview and self.preview.state and self.preview.state.win or nil,
    transport = self.options and self.options.transport or "auto",
    tools = {
      magick = self.options.magick,
      rsvg = self.options.rsvg,
      pdfinfo = self.options.pdfinfo,
      pngpaste = self.options.insert.pngpaste or "pngpaste",
      math_latex = self.options.math.latex,
      math_dvipng = self.options.math.dvipng,
    },
    cell_size = vim.deepcopy(self.options.cell_size),
    disk_cache = vim.tbl_extend("force", self.options.disk_cache, { path = self.options.cache }),
    conversion_queue = require("image_tools.media.conversion_queue").status(),
    media = require("image_tools.media.prepare").status(),
    treesitter = vim.tbl_extend(
      "force",
      require("image_tools.document.treesitter").status(),
      { enabled = self.options.treesitter }
    ),
    terminal_cache = self:terminal_status(),
  }
end

-- Revalidate pending/visible selection and retain unchanged source authority; automatic preview
-- starts only when enabled.
---@return nil
function Runtime:refresh()
  if self.disposed then
    return
  end
  if self.pending_reference then
    if owns_pending(self.pending_reference) then
      return
    end
    self:close()
  end
  local state = self.preview and self.preview.state
  if state and not on_current_line(state) then
    self:close()
    state = nil
  end
  if state then
    if
      state.changedtick == vim.api.nvim_buf_get_changedtick(0)
      and state.cursor[1] == vim.api.nvim_win_get_cursor(0)[1]
      and (not state.reference or state.cursor[2] == vim.api.nvim_win_get_cursor(0)[2])
    then
      return -- Reference previews recheck horizontal movement for another image.
    end
    if state.reference then
      self:hover({ silent = true, automatic = true })
      return
    end
    self:close()
  end
  if self.options.auto_preview then
    local document = self.dependencies.document or require("image_tools.document.formats")
    if document.supported(vim.bo.filetype) then
      self:hover({ silent = true, automatic = true })
    end
  end
end

-- Register a guarded callback in this Runtime autocmd group.
---@param events string|string[] Neovim event names.
---@param opts table Autocmd options; group/callback are bound to this instance.
---@return nil
function Runtime:autocmd(events, opts)
  opts.group = self.group
  opts.callback = self:bind(opts.callback)
  vim.api.nvim_create_autocmd(events, opts)
end

-- Configure the shared process budget, install commands/events and start file-buffer interception.
---@return nil
function Runtime:start()
  assert(not self.disposed and not self.group, "Runtime is already started or destroyed")
  require("image_tools.media.conversion_queue").configure(self.options.convert_concurrency)
  self.group = vim.api.nvim_create_augroup("image_tools", { clear = true })

  self:autocmd({
    "CursorMoved",
    "CursorMovedI",
    "CursorHold",
    "CursorHoldI",
    "InsertEnter",
    "TextChanged",
    "TextChangedI",
    "TextChangedP",
  }, {
    callback = function()
      self:refresh()
    end,
  })

  self:autocmd({ "BufEnter", "WinEnter", "VimResume" }, {
    callback = function()
      self:schedule_refresh()
    end,
  })

  self:autocmd({ "FocusGained", "CursorHold", "CursorHoldI" }, {
    callback = function()
      self:refresh_source()
    end,
  })

  self:autocmd({
    "BufLeave",
    "WinLeave",
  }, {
    callback = function()
      self:close()
    end,
  })

  self:autocmd({ "VimSuspend", "ExitPre", "VimLeavePre" }, {
    callback = function()
      self:clear_cache()
    end,
  })

  self:autocmd({ "VimResized", "ColorScheme" }, {
    callback = function()
      self:close()
      self:schedule_refresh()
    end,
  })

  self:autocmd({ "WinResized", "WinScrolled" }, {
    callback = function()
      if self.preview and self.preview.state then
        for _, win in ipairs(vim.v.event.windows or {}) do
          if win == self.preview.state.owner_win then
            self:close()
            self:schedule_refresh()
            return
          end
        end
      end
    end,
  })

  self:autocmd("WinClosed", {
    callback = function(event)
      if
        self.preview
        and self.preview.state
        and (tonumber(event.match) == self.preview.state.win or tonumber(event.match) == self.preview.state.owner_win)
      then
        self:close()
      end
    end,
  })

  self:autocmd({ "BufDelete", "BufWipeout" }, {
    callback = function(event)
      if
        self.preview
        and self.preview.state
        and (event.buf == self.preview.state.owner_buf or event.buf == self.preview.state.buf)
      then
        self:close()
      end
    end,
  })

  require("image_tools.commands").register(self)
  self.buffers:setup()
  self:schedule_refresh()
end

return Runtime
