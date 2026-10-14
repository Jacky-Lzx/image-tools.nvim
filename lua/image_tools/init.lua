local M = {}
local defaults = {
  auto_preview = true,
  buffer = {
    enabled = true,
    formats = { "png", "jpg", "jpeg", "webp", "avif", "heic", "gif", "bmp", "tif", "tiff", "pdf" },
  },
  pdfinfo = "pdfinfo",
  pdf_density = 144,
  insert = { directory = "Figures", mode = "copy", insert_strategy = "insert_line_after", prompt_for_file_name = false },
  position = "cursor", -- "cursor" or "bottom_right"
  transport = "auto", -- "auto", "file" or "direct"
  terminal_timeout = 1500,
  terminal_cache = { max_images = 32, max_bytes = 64 * 1024 * 1024 },
  max_width = 60,
  max_height = 30,
  border = "rounded",
  force = false,
  cell_size = { width = 10, height = 20 },
  max_bytes = 32 * 1024 * 1024,
  max_dimension = 16384,
  max_pixels = 64 * 1024 * 1024,
  max_scan_lines = 10000,
  convert_timeout = 10000,
  magick = "magick",
  rsvg = "rsvg-convert",
}
local preview, options, group, refresh, buffers

local function on_current_line(state)
  return state
    and state.owner_buf == vim.api.nvim_get_current_buf()
    and state.owner_win == vim.api.nvim_get_current_win()
    and state.cursor[1] == vim.api.nvim_win_get_cursor(0)[1]
end

local function schedule_refresh()
  local instance = preview
  vim.schedule(function()
    if preview == instance then
      refresh()
    end
  end)
end

function M.close()
  if preview then
    preview:close()
  end
end

function M.clear_cache()
  if buffers then
    buffers:clear_cache()
  end
  if package.loaded["image_tools.picker"] then
    require("image_tools.picker").clear_all()
  end
  if preview then
    preview:destroy()
  end
end

function M.preview(path, opts)
  if not preview then
    M.setup()
  end
  if type(path) ~= "string" or path == "" then
    return false, "An image path is required"
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return preview:open(path, opts)
end

function M.insert(paths, opts, callback)
  if not options then
    M.setup()
  end
  local insertion = require("image_tools.insert")
  opts = vim.tbl_extend(
    "force",
    options.insert,
    { max_bytes = options.max_bytes, reference_root = options.root },
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

function M.paste(opts, callback)
  if not options then
    M.setup()
  end
  local insertion = vim.tbl_extend("force", options.insert, {
    max_bytes = options.max_bytes,
    max_dimension = options.max_dimension,
    max_pixels = options.max_pixels,
    magick = options.magick,
    convert_timeout = options.convert_timeout,
    reference_root = options.root,
  }, opts or {})
  return require("image_tools.clipboard").paste(insertion, callback)
end

function M.snacks_preview(ctx)
  if not options then
    M.setup()
  end
  return require("image_tools.picker").preview(ctx, options)
end

function M.pick(opts, callback)
  if not options then
    M.setup()
  end
  opts = opts or {}
  local insertion = vim.tbl_extend(
    "force",
    options.insert,
    { max_bytes = options.max_bytes, reference_root = options.root },
    opts.insert or {}
  )
  return require("image_tools.picker").pick(insertion, opts.picker, M.snacks_preview, callback)
end

function M.open(path)
  if not buffers then
    M.setup()
  end
  return buffers:open(path)
end
function M.page(page)
  if not buffers then
    M.setup()
  end
  return buffers:page(page)
end
function M.next_page(delta)
  if not buffers then
    M.setup()
  end
  return buffers:step(delta or 1)
end
function M.reload()
  if not buffers then
    M.setup()
  end
  return buffers:reload(vim.api.nvim_get_current_buf())
end

function M.hover(opts)
  if not preview then
    M.setup()
  end
  opts = opts or {}
  local cursor = vim.api.nvim_win_get_cursor(0)
  local path, err = require("image_tools.document").at_line(0, cursor[1], options)
  if not path then
    M.close()
    if not opts.silent then
      vim.notify(err, vim.log.levels.INFO, { title = "image-tools" })
    end
    return false, err
  end
  if on_current_line(preview.state) and preview.state.path == path then
    -- A text edit elsewhere on the same line must not invalidate a pending
    -- conversion when the resolved image source is unchanged.
    preview.state.changedtick = vim.api.nvim_buf_get_changedtick(0)
    preview.state.reference = true
    return true
  end
  return M.preview(path, vim.tbl_extend("force", opts, { reference = true }))
end

function M.toggle()
  if not preview then
    M.setup()
  end
  options.auto_preview = not options.auto_preview
  M.close()
  if options.auto_preview then
    refresh()
  end
  vim.notify(
    "Automatic image preview " .. (options.auto_preview and "enabled" or "disabled"),
    vim.log.levels.INFO,
    { title = "image-tools" }
  )
  return options.auto_preview
end

function M.status()
  return {
    configured = preview ~= nil,
    buffer = buffers and buffers:status() or nil,
    auto_preview = options and options.auto_preview or false,
    path = preview and preview.state and preview.state.path or nil,
    window = preview and preview.state and preview.state.win or nil,
    transport = options and options.transport or "auto",
    terminal_cache = preview and preview.transfer:status() or nil,
  }
end

refresh = function()
  local state = preview.state
  if state and not on_current_line(state) then
    M.close()
    state = nil
  end
  if state then
    if state.changedtick == vim.api.nvim_buf_get_changedtick(0) then
      return -- Keep both visible and pending previews during horizontal movement.
    end
    if state.reference then
      M.hover({ silent = true })
      return
    end
    M.close()
  end
  if options.auto_preview and require("image_tools.document").supported(vim.bo.filetype) then
    M.hover({ silent = true })
  end
end

function M.setup(opts)
  M.clear_cache()
  if buffers then
    buffers:destroy()
    buffers = nil
  end
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  options.cache = options.cache or (vim.fn.stdpath("cache") .. "/image-tools")
  assert(options.position == "cursor" or options.position == "bottom_right", "position must be cursor or bottom_right")
  assert(vim.tbl_contains({ "auto", "file", "direct" }, options.transport), "transport must be auto, file or direct")
  for _, name in ipairs({ "max_images", "max_bytes" }) do
    assert(
      type(options.terminal_cache[name]) == "number"
        and options.terminal_cache[name] >= 0
        and options.terminal_cache[name] % 1 == 0,
      "terminal_cache." .. name .. " must be a non-negative integer"
    )
  end
  for _, name in ipairs({
    "max_width",
    "max_height",
    "max_bytes",
    "max_dimension",
    "max_pixels",
    "max_scan_lines",
    "convert_timeout",
    "terminal_timeout",
    "pdf_density",
  }) do
    assert(
      type(options[name]) == "number" and options[name] >= 1 and options[name] % 1 == 0,
      name .. " must be a positive integer"
    )
  end
  assert(options.cell_size.width > 0 and options.cell_size.height > 0, "cell_size must be positive")
  assert(type(options.buffer.enabled) == "boolean", "buffer.enabled must be boolean")
  for _, extension in ipairs(options.buffer.formats) do
    assert(
      type(extension) == "string"
        and extension:match("^%a+$")
        and require("image_tools.image").supported("file." .. extension),
      "Unsupported buffer format"
    )
  end
  preview = require("image_tools.preview").new(options)
  group = vim.api.nvim_create_augroup("image_tools", { clear = true })
  vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "CursorHold",
    "CursorHoldI",
    "InsertEnter",
    "TextChanged",
    "TextChangedI",
    "TextChangedP",
  }, {
    group = group,
    callback = refresh,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "VimResume" }, {
    group = group,
    callback = schedule_refresh,
  })
  vim.api.nvim_create_autocmd({
    "BufLeave",
    "WinLeave",
  }, {
    group = group,
    callback = M.close,
  })
  vim.api.nvim_create_autocmd({ "VimSuspend", "ExitPre", "VimLeavePre" }, { group = group, callback = M.clear_cache })
  vim.api.nvim_create_autocmd({ "VimResized", "ColorScheme" }, {
    group = group,
    callback = function()
      M.close()
      schedule_refresh()
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "WinScrolled" }, {
    group = group,
    callback = function()
      if preview.state then
        for _, win in ipairs(vim.v.event.windows or {}) do
          if win == preview.state.owner_win then
            M.close()
            schedule_refresh()
            return
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      if
        preview.state
        and (tonumber(event.match) == preview.state.win or tonumber(event.match) == preview.state.owner_win)
      then
        M.close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      if preview.state and (event.buf == preview.state.owner_buf or event.buf == preview.state.buf) then
        M.close()
      end
    end,
  })
  local function report(ok, err)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
    end
  end
  vim.api.nvim_create_user_command("ImageOpen", function(args)
    report(M.open(args.args))
  end, { nargs = 1, complete = "file", desc = "Open an image/PDF in a read-only buffer", force = true })
  vim.api.nvim_create_user_command("ImagePage", function(args)
    report(M.page(tonumber(args.args)))
  end, { nargs = 1, desc = "Display a PDF page", force = true })
  vim.api.nvim_create_user_command("ImageNextPage", function(args)
    report(M.next_page(args.count))
  end, { count = 1, desc = "Next PDF page", force = true })
  vim.api.nvim_create_user_command("ImagePreviousPage", function(args)
    report(M.next_page(-args.count))
  end, { count = 1, desc = "Previous PDF page", force = true })
  vim.api.nvim_create_user_command("ImageReload", function()
    report(M.reload())
  end, { desc = "Reload the current image/PDF buffer", force = true })
  vim.api.nvim_create_user_command("ImagePick", function()
    M.pick()
  end, { desc = "Choose images with an independent Snacks picker preview", force = true })
  vim.api.nvim_create_user_command("ImagePaste", function()
    M.paste()
  end, { desc = "Paste a macOS clipboard image", force = true })
  vim.api.nvim_create_user_command(
    "ImageInsert",
    function(args)
      M.insert(args.args ~= "" and args.args or nil, { mode = args.bang and "reference" or options.insert.mode })
    end,
    { nargs = "?", bang = true, complete = "file", desc = "Import an image (! references the source)", force = true }
  )
  vim.api.nvim_create_user_command("ImagePreview", function(args)
    if args.args == "" then
      M.hover()
    else
      M.preview(args.args)
    end
  end, {
    nargs = "?",
    complete = "file",
    desc = "Preview an image file or the first image reference on the current line",
    force = true,
  })
  vim.api.nvim_create_user_command("ImagePreviewClose", M.close, { desc = "Close the image preview", force = true })
  vim.api.nvim_create_user_command(
    "ImagePreviewClearCache",
    M.clear_cache,
    { desc = "Close preview and release all image-tools terminal images", force = true }
  )
  vim.api.nvim_create_user_command(
    "ImagePreviewToggle",
    M.toggle,
    { desc = "Toggle automatic image preview", force = true }
  )
  buffers = require("image_tools.buffer").new(options)
  buffers:setup()
  schedule_refresh()
end

return M
