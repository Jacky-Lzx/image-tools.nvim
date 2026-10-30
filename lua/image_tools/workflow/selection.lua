-- Image import chooser over selection-tools. The picker owns search/focus/panes;
-- image-tools owns rendering and the captured document insertion transaction.
local M = {}

local function preview(render)
  return function(ctx)
    if type(ctx.paint) ~= "function" then
      ctx.set_lines({ "ImagePick requires selection-tools with preview provider support" })
      return
    end
    if
      not ctx.paint(function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading image…" })
      end, { title = vim.fs.basename(ctx.path) })
    then
      return
    end
    local view, err = render({
      path = ctx.path,
      buf = ctx.buf,
      win = ctx.win,
      is_valid = function()
        return not ctx.is_cancelled()
      end,
      paint = function(draw)
        return ctx.paint(draw, { title = vim.fs.basename(ctx.path) })
      end,
      on_error = function(message)
        ctx.set_lines({ "Image preview: " .. tostring(message) })
      end,
    })
    if not view then
      ctx.set_lines({ "Image preview: " .. tostring(err) })
    end
    return view
  end
end

---@param insertion ImageToolsInsertOptions
---@param opts? table selection-tools files() options; ft optionally restricts formats.
---@param render fun(request: ImageToolsEmbeddedRequest): ImageToolsEmbeddedView?, string?
---@param callback? ImageToolsInsertCallback
---@return table? picker
function M.pick(insertion, opts, render, callback)
  local I = require("image_tools.workflow.insert")
  local context = insertion.context or I.capture(insertion)
  insertion = vim.tbl_extend("force", insertion, { context = context })
  local finished, decided = false, false
  local function finish(err, paths)
    if finished then
      return
    end
    finished = true
    if err then
      I.release(context)
    end
    if callback then
      callback(err, paths)
    elseif err and err ~= "Cancelled" then
      vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
    end
  end
  local adapter = require("image_tools.document").adapter(context.filetype)
  if not adapter then
    finish("Unsupported image insertion filetype")
    return
  end
  local formats = adapter.image_formats()
  if insertion.process and insertion.mode ~= "reference" then
    formats = require("image_tools.media.formats").extensions()
  end
  opts = opts or {}
  if opts.ft then
    if type(opts.ft) ~= "string" and (type(opts.ft) ~= "table" or not vim.islist(opts.ft)) then
      finish("ft must be an extension or a list of extensions")
      return
    end
    local requested = type(opts.ft) == "string" and { opts.ft } or opts.ft
    for _, extension in ipairs(requested) do
      if type(extension) ~= "string" then
        finish("ft extensions must be strings")
        return
      end
    end
    local allowed = {}
    for _, extension in ipairs(formats) do
      allowed[extension] = true
    end
    formats = vim.tbl_filter(function(extension)
      return allowed[extension:lower()]
    end, requested)
  end
  if #formats == 0 then
    finish("No supported image formats selected")
    return
  end
  local globs = {}
  for _, extension in ipairs(formats) do
    -- Bracket patterns preserve mixed-case extensions with rg's normal glob API.
    globs[#globs + 1] = "*."
      .. extension:gsub("%a", function(char)
        return "[" .. char:lower() .. char:upper() .. "]"
      end)
  end
  local config = vim.tbl_deep_extend("force", {
    prompt = "Images",
    globs = globs,
    multi = true,
    preview = { enabled = true },
    previewer = preview(render),
  }, opts)
  -- Captured insertion extmarks are single-use and cannot be resumed after close.
  config.resume = false
  config.actions = config.actions or {}
  config.actions.confirm = function(picker)
    picker:confirm()
  end
  local user_choice = config.on_choice
  config.on_choice = function(item, index, selected)
    if decided then
      return
    end
    decided = true
    if not item then
      finish("Cancelled")
    else
      local paths = {}
      for _, value in ipairs(selected or { item }) do
        if value.file then
          paths[#paths + 1] = value.file
        end
      end
      if #paths == 0 then
        finish("No image paths selected")
      else
        vim.schedule(function()
          I.files(paths, insertion, finish)
        end)
      end
    end
    if user_choice then
      user_choice(item, index, selected)
    end
  end
  local loaded, selection = pcall(require, "selection_tools")
  if not loaded or type(selection.files) ~= "function" then
    finish("ImagePick requires selection-tools.nvim")
    return
  end
  local ok, picker = pcall(selection.files, config)
  if not ok then
    finish(tostring(picker))
    return
  end
  return picker
end
return M
