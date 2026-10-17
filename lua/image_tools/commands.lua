-- Module: image_tools.commands
--
-- Purpose:
--   Register user commands against a particular Runtime.
--
-- Architecture:
--   Translate command arguments into Runtime operations and bind callbacks
--   through its disposal guard. Command implementations reuse services rather
--   than owning separate preview state.
--
-- Ownership:
--   Record registered names on the Runtime so destruction can remove them. This
--   module keeps no active editor instance.

local M = {}

-- Install command callbacks guarded by the owning Runtime and record their names for teardown.
---@param runtime ImageToolsRuntime Instance that owns command execution and cleanup.
---@return nil
function M.register(runtime)
  runtime.commands = {}

  -- Create one command and retain its name for later Runtime destruction.
  ---@param name string User command name.
  ---@param callback function Runtime-bound command implementation.
  ---@param opts table Neovim user-command options.
  ---@return nil
  local function command(name, callback, opts)
    vim.api.nvim_create_user_command(name, runtime:bind(callback), opts)
    runtime.commands[#runtime.commands + 1] = name
  end

  -- Notify only failed command operations; successful requests may still complete asynchronously.
  ---@param ok? boolean Accepted-operation flag.
  ---@param err any Failure message required when ok is false; ignored on success.
  ---@return nil
  local function report(ok, err)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
    end
  end

  command("ImageOpen", function(args)
    report(runtime:open(args.args))
  end, { nargs = 1, complete = "file", desc = "Open an image/PDF in a read-only buffer", force = true })

  command("ImageMove", function(args)
    local document = require("image_tools.document")
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local opts = vim.tbl_extend("force", runtime.options, { treesitter = false })
    local source, err, status = document.at_cursor(buf, row, col, opts)
    if not source and status == "miss" then
      source, err = document.at_line(buf, row, opts)
    end
    if not source or source:match("^image%-tools%-math:") then
      report(false, err or "Select a local image reference before moving it")
      return
    end
    runtime:move(source, args.args)
  end, {
    nargs = 1,
    complete = "file",
    desc = "Move the selected image and review project reference updates",
    force = true,
  })

  command("ImagePage", function(args)
    report(runtime:page(tonumber(args.args)))
  end, { nargs = 1, desc = "Display a PDF page", force = true })

  command("ImageNextPage", function(args)
    report(runtime:next_page(args.count))
  end, { count = 1, desc = "Next PDF page", force = true })

  command("ImagePreviousPage", function(args)
    report(runtime:next_page(-args.count))
  end, { count = 1, desc = "Previous PDF page", force = true })

  command("ImageInfo", function()
    local info, err = runtime:info()
    if not info then
      report(false, err)
      return
    end
    local lines = {
      info.path,
      "Format: " .. (info.format or "unknown"),
      "Source: " .. (info.bytes and (info.bytes .. " bytes") or "missing/unreadable"),
      "Prepared raster: " .. (info.width and string.format("%d x %d pixels", info.width, info.height) or "pending"),
      "State: " .. (info.stage or (info.ready and "ready" or "preparing")),
    }
    if info.error then
      lines[#lines + 1] = "Error"
        .. (info.error_stage and (" (" .. info.error_stage .. ")") or "")
        .. ": "
        .. info.error
    end
    if info.last_error then
      lines[#lines + 1] = "Most recent failed preview"
    end
    if info.page then
      lines[#lines + 1] = "PDF page: " .. info.page .. " / " .. (info.pages or "?")
    end
    if info.zoom then
      lines[#lines + 1] = "Zoom: " .. tostring(info.zoom)
    end
    local cache = info.terminal_cache or { images = 0, hits = 0, uploads = 0 }
    lines[#lines + 1] =
      string.format("Terminal cache: %d image(s), %d hit(s), %d upload(s)", cache.images, cache.hits, cache.uploads)
    lines[#lines + 1] = "Disk cache: " .. info.disk_cache
    if info.timings then
      for _, field in ipairs({
        { "lookup_ms", "Reference lookup" },
        { "automatic_delay_ms", "Automatic delay" },
        { "preparation_ms", "Preparation (includes queue/conversion)" },
        { "queue_ms", "Queue wait" },
        { "conversion_ms", "Conversion process" },
        { "transfer_ms", "Transfer (includes upload/placement)" },
        { "upload_ms", "Upload wait" },
        { "placement_ms", "Placement replies" },
        { "draw_ms", "Placeholder drawing" },
        { "total_ms", "Total" },
      }) do
        local value = info.timings[field[1]]
        if value then
          lines[#lines + 1] = string.format("%s: %.2f ms", field[2], value)
        end
      end
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "image-tools" })
  end, { desc = "Show current image/PDF metadata and cache statistics", force = true })

  command("ImageCheckAssets", function(args)
    if args.args ~= "" and not args.bang then
      report(false, "Use :ImageCheckAssets! [directory] for project inspection")
      return
    end
    runtime:check_assets(
      { scope = args.bang and "project" or "document", project_root = args.args ~= "" and args.args or nil },
      function(err, result)
        if err then
          report(false, err)
          return
        end
        local items = vim.deepcopy(result.missing)
        for _, path in ipairs(result.unreferenced) do
          items[#items + 1] = {
            filename = path,
            lnum = 1,
            text = result.scope == "project" and "Possibly unused in scanned project documents"
              or "Possibly unused in this document (may be used elsewhere)",
            type = "W",
          }
        end
        if result.scope == "project" then
          for _, message in ipairs(result.warnings) do
            items[#items + 1] = { text = message .. "; unused results are incomplete", type = "W" }
          end
        elseif result.truncated then
          items[#items + 1] = {
            filename = result.document,
            lnum = result.scanned,
            text = "Scan stopped at max_scan_lines; unused results are incomplete",
            type = "W",
          }
        end
        vim.fn.setqflist(
          {},
          " ",
          { title = "Image assets: " .. (result.project_root or result.document), items = items }
        )
        if #items > 0 then
          vim.cmd("copen")
        else
          vim.notify("No image asset issues found")
        end
      end
    )
  end, { bang = true, nargs = "?", complete = "dir", desc = "Check image assets (! scans a project)", force = true })

  command("ImageZoom", function(args)
    report(runtime:zoom(tonumber(args.args) or args.args))
  end, { nargs = 1, desc = "Set viewer zoom (fit/native/in/out/factor)", force = true })

  command("ImagePan", function(args)
    if #args.fargs ~= 2 then
      report(false, "ImagePan requires X Y offsets in terminal cells")
      return
    end
    report(runtime:pan(tonumber(args.fargs[1]), tonumber(args.fargs[2])))
  end, { nargs = "+", desc = "Pan viewer by horizontal/vertical terminal cells", force = true })

  command("ImageReload", function()
    report(runtime:reload())
  end, { desc = "Reload the current image/PDF buffer", force = true })

  command("ImagePick", function()
    runtime:pick()
  end, { desc = "Choose images with an independent Snacks picker preview", force = true })

  command("ImagePaste", function()
    runtime:paste()
  end, { desc = "Paste a clipboard image", force = true })

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
    desc = "Preview an image file or the image reference under the cursor",
    force = true,
  })

  command("ImagePreviewClose", function()
    runtime:close()
  end, { desc = "Close the image preview", force = true })

  command("ImagePreviewClearCache", function()
    runtime:clear_cache()
  end, { desc = "Close preview and release all image-tools terminal images", force = true })

  command("ImageCacheClear", function()
    runtime:clear_disk_cache(function(status)
      local message = status.error
        or string.format("Removed %d cached files; %d files still in use", status.removed, status.protected)
      vim.notify(message, status.error and vim.log.levels.ERROR or vim.log.levels.INFO, { title = "image-tools" })
    end)
  end, { desc = "Clear unused converted images from disk", force = true })
  command("ImagePreviewToggle", function()
    runtime:toggle()
  end, { desc = "Toggle automatic image preview", force = true })
end

return M
