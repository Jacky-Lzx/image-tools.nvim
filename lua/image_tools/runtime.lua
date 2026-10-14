local Runtime = {}
Runtime.__index = Runtime

function Runtime.new(options, dependencies)
  local self = setmetatable({
    options = options,
    dependencies = vim.tbl_extend("force", {}, dependencies or {}),
    disposed = false,
    renderers = setmetatable({}, { __mode = "k" }),
  }, Runtime)
  self.dependencies.pixel_pool = require("image_tools.pixel_pool").new(options, self.dependencies)
  self.preview = self:dependency("preview").new(options, self.dependencies)
  self.buffers = self:dependency("buffer").new(options, self.dependencies)
  return self
end

function Runtime:dependency(name)
  return self.dependencies[name] or require("image_tools." .. name)
end

function Runtime:bind(callback)
  return function(...)
    if not self.disposed then
      return callback(...)
    end
  end
end

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

function Runtime:destroy()
  if self.disposed then
    return
  end
  -- Disable callbacks before closing windows, which can trigger more events.
  self.disposed = true
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

local function covers(range, row, original)
  return range and row >= range.start_row and row <= range.end_row or not range and row == original
end
local function on_current_line(state)
  return state
    and state.owner_buf == vim.api.nvim_get_current_buf()
    and state.owner_win == vim.api.nvim_get_current_win()
    and covers(state.reference_range, vim.api.nvim_win_get_cursor(0)[1], state.cursor[1])
end
local function owns_pending(request)
  return request.buf == vim.api.nvim_get_current_buf()
    and request.win == vim.api.nvim_get_current_win()
    and request.tick == vim.api.nvim_buf_get_changedtick(0)
    and covers(request.range, vim.api.nvim_win_get_cursor(0)[1], request.row)
end
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

function Runtime:close()
  self.reference_request = nil
  self.pending_reference = nil
  if self.preview then
    self.preview:close()
  end
end

function Runtime:clear_cache()
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
  self.dependencies.pixel_pool:clear()
end

function Runtime:clear_disk_cache(callback)
  return self:dependency("disk_cache").clear(self.options, callback)
end

function Runtime:open_preview(path, opts)
  if type(path) ~= "string" or path == "" then
    return false, "An image path is required"
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return self.preview:open(path, opts)
end

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

function Runtime:snacks_preview(ctx)
  local result = self:dependency("picker").preview(ctx, self.options, self.dependencies)
  local renderer = ctx.picker._image_tools_preview
  if renderer then
    self.renderers[renderer] = true
  end
  return result
end

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

function Runtime:open(path)
  return self.buffers:open(path)
end
function Runtime:page(page)
  return self.buffers:page(page)
end
function Runtime:next_page(delta)
  return self.buffers:step(delta or 1)
end
function Runtime:reload()
  return self.buffers:reload(vim.api.nvim_get_current_buf())
end

function Runtime:hover(opts)
  opts = opts or {}
  local cursor = vim.api.nvim_win_get_cursor(0)
  local buf, win, tick =
    vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_buf_get_changedtick(0)
  local pending = self.pending_reference
  if pending and owns_pending(pending) then
    return false, "Tree-sitter parsing is pending"
  end
  local request = { buf = buf, win = win, row = cursor[1], tick = tick }
  self.reference_request = request
  local options = vim.tbl_extend("force", self.options, {
    _treesitter_ready = function()
      if not self.disposed and self.reference_request == request and owns_pending(request) then
        self.pending_reference = nil
        self:hover(opts)
      end
    end,
  })
  local path, err, status, reference = self:dependency("document").at_line(buf, cursor[1], options)
  request.range = range_of(reference)
  if status == "pending" then
    self.pending_reference = request
    self.preview:close()
    return false, err
  end
  if not path then
    self:close()
    if not opts.silent then
      vim.notify(err, vim.log.levels.INFO, { title = "image-tools" })
    end
    return false, err
  end
  if on_current_line(self.preview.state) and self.preview.state.path == path then
    -- A text edit elsewhere on the same line must not invalidate a pending
    -- conversion when the resolved image source is unchanged.
    self.preview.state.changedtick = vim.api.nvim_buf_get_changedtick(0)
    self.preview.state.reference = true
    self.preview.state.reference_range = request.range
    self.preview.state.cursor = cursor
    return true
  end
  return self:open_preview(path, vim.tbl_extend("force", opts, { reference = true, reference_range = request.range }))
end

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

function Runtime:status()
  return {
    configured = not self.disposed,
    buffer = self.buffers and self.buffers:status() or nil,
    auto_preview = self.options and self.options.auto_preview or false,
    path = self.preview and self.preview.state and self.preview.state.path or nil,
    window = self.preview and self.preview.state and self.preview.state.win or nil,
    transport = self.options and self.options.transport or "auto",
    disk_cache = vim.tbl_extend("force", self.options.disk_cache, { path = self.options.cache }),
    conversion_queue = require("image_tools.conversion_queue").status(),
    media = require("image_tools.media.prepare").status(),
    treesitter = vim.tbl_extend(
      "force",
      require("image_tools.document.treesitter").status(),
      { enabled = self.options.treesitter }
    ),
    terminal_cache = self.preview and self.preview.transfer:status() or nil,
  }
end

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
  local state = self.preview.state
  if state and not on_current_line(state) then
    self:close()
    state = nil
  end
  if state then
    if
      state.changedtick == vim.api.nvim_buf_get_changedtick(0)
      and state.cursor[1] == vim.api.nvim_win_get_cursor(0)[1]
    then
      return -- Keep both visible and pending previews during horizontal movement.
    end
    if state.reference then
      self:hover({ silent = true })
      return
    end
    self:close()
  end
  if self.options.auto_preview and self:dependency("document").supported(vim.bo.filetype) then
    self:hover({ silent = true })
  end
end

function Runtime:autocmd(events, opts)
  opts.group = self.group
  opts.callback = self:bind(opts.callback)
  vim.api.nvim_create_autocmd(events, opts)
end

function Runtime:start()
  assert(not self.disposed and not self.group, "Runtime is already started or destroyed")
  require("image_tools.conversion_queue").configure(self.options.convert_concurrency)
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
      if self.preview.state then
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
        self.preview.state
        and (tonumber(event.match) == self.preview.state.win or tonumber(event.match) == self.preview.state.owner_win)
      then
        self:close()
      end
    end,
  })

  self:autocmd({ "BufDelete", "BufWipeout" }, {
    callback = function(event)
      if self.preview.state and (event.buf == self.preview.state.owner_buf or event.buf == self.preview.state.buf) then
        self:close()
      end
    end,
  })

  require("image_tools.commands").register(self)
  self.buffers:setup()
  self:schedule_refresh()
end

return Runtime
