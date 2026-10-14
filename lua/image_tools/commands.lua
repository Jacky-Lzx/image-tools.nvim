local M = {}

function M.register(runtime)
  runtime.commands = {}
  local function command(name, callback, opts)
    vim.api.nvim_create_user_command(name, runtime:bind(callback), opts)
    runtime.commands[#runtime.commands + 1] = name
  end
  local function report(ok, err)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
    end
  end
  command("ImageOpen", function(args)
    report(runtime:open(args.args))
  end, { nargs = 1, complete = "file", desc = "Open an image/PDF in a read-only buffer", force = true })
  command("ImagePage", function(args)
    report(runtime:page(tonumber(args.args)))
  end, { nargs = 1, desc = "Display a PDF page", force = true })
  command("ImageNextPage", function(args)
    report(runtime:next_page(args.count))
  end, { count = 1, desc = "Next PDF page", force = true })
  command("ImagePreviousPage", function(args)
    report(runtime:next_page(-args.count))
  end, { count = 1, desc = "Previous PDF page", force = true })
  command("ImageReload", function()
    report(runtime:reload())
  end, { desc = "Reload the current image/PDF buffer", force = true })
  command("ImagePick", function()
    runtime:pick()
  end, { desc = "Choose images with an independent Snacks picker preview", force = true })
  command("ImagePaste", function()
    runtime:paste()
  end, { desc = "Paste a macOS clipboard image", force = true })
  command(
    "ImageInsert",
    function(args)
      runtime:insert(
        args.args ~= "" and args.args or nil,
        { mode = args.bang and "reference" or runtime.options.insert.mode }
      )
    end,
    { nargs = "?", bang = true, complete = "file", desc = "Import an image (! references the source)", force = true }
  )
  command("ImagePreview", function(args)
    if args.args == "" then
      runtime:hover()
    else
      runtime:open_preview(args.args)
    end
  end, {
    nargs = "?",
    complete = "file",
    desc = "Preview an image file or the first image reference on the current line",
    force = true,
  })
  command("ImagePreviewClose", function()
    runtime:close()
  end, { desc = "Close the image preview", force = true })
  command("ImagePreviewClearCache", function()
    runtime:clear_cache()
  end, { desc = "Close preview and release all image-tools terminal images", force = true })
  command("ImagePreviewToggle", function()
    runtime:toggle()
  end, { desc = "Toggle automatic image preview", force = true })
end

return M
