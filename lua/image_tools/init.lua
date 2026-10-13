local M = {}
local defaults = {
  auto_preview = true,
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
}
local preview, options, group

function M.close()
  if preview then
    preview:close()
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

function M.hover(opts)
  if not preview then
    M.setup()
  end
  opts = opts or {}
  local cursor = vim.api.nvim_win_get_cursor(0)
  local path, err = require("image_tools.document").at_cursor(0, cursor[1], cursor[2], options)
  if not path then
    M.close()
    if not opts.silent then
      vim.notify(err, vim.log.levels.INFO, { title = "image-tools" })
    end
    return false, err
  end
  if opts.silent and preview.state and preview.state.path == path then
    return true
  end
  return M.preview(path, opts)
end

function M.toggle()
  if not preview then
    M.setup()
  end
  options.auto_preview = not options.auto_preview
  M.close()
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
    auto_preview = options and options.auto_preview or false,
    path = preview and preview.state and preview.state.path or nil,
    window = preview and preview.state and preview.state.win or nil,
  }
end

function M.setup(opts)
  M.close()
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  options.cache = options.cache or (vim.fn.stdpath("cache") .. "/image-tools")
  for _, name in ipairs({
    "max_width",
    "max_height",
    "max_bytes",
    "max_dimension",
    "max_pixels",
    "max_scan_lines",
    "convert_timeout",
  }) do
    assert(
      type(options[name]) == "number" and options[name] >= 1 and options[name] % 1 == 0,
      name .. " must be a positive integer"
    )
  end
  assert(options.cell_size.width > 0 and options.cell_size.height > 0, "cell_size must be positive")
  preview = require("image_tools.preview").new(options)
  group = vim.api.nvim_create_augroup("image_tools", { clear = true })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function()
      if options.auto_preview and vim.bo.filetype == "markdown" and vim.fn.mode() == "n" then
        M.hover({ silent = true })
      end
    end,
  })
  vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "InsertEnter",
    "BufLeave",
    "WinLeave",
    "TextChanged",
    "TextChangedI",
    "VimResized",
    "ColorScheme",
    "VimSuspend",
    "ExitPre",
  }, {
    group = group,
    callback = M.close,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "WinScrolled" }, {
    group = group,
    callback = function()
      if preview.state then
        for _, win in ipairs(vim.v.event.windows or {}) do
          if win == preview.state.owner_win then
            M.close()
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
  vim.api.nvim_create_user_command("ImagePreview", function(args)
    if args.args == "" then
      M.hover()
    else
      M.preview(args.args)
    end
  end, {
    nargs = "?",
    complete = "file",
    desc = "Preview an image file or the Markdown image under the cursor",
    force = true,
  })
  vim.api.nvim_create_user_command("ImagePreviewClose", M.close, { desc = "Close the image preview", force = true })
  vim.api.nvim_create_user_command(
    "ImagePreviewToggle",
    M.toggle,
    { desc = "Toggle automatic image preview", force = true }
  )
end

return M
