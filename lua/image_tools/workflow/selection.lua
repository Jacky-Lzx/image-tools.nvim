-- Image import chooser over selection-tools. The picker owns search/focus/panes;
-- image-tools owns rendering and the captured document insertion transaction.
local M = {}

local function preview(render)
  return function(ctx)
    if type(ctx.paint) ~= "function" then
      ctx.set_lines({ "ImagePick requires selection-tools with preview provider support" })
      return true
    end
    if not ctx.previous and not ctx.has_preview then
      if
        not ctx.paint(function(buf)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading image…" })
        end, { title = vim.fs.basename(ctx.path) })
      then
        return true
      end
    end
    local view, err = render({
      path = ctx.path,
      previous = ctx.previous,
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
    return view or true
  end
end

-- Review per-document diffs in the picker, then explicitly confirm the full plan.
-- The returned handle owns both picker stages; closing it never applies the plan.
function M.review(plan, callback)
  local selection = require("selection_tools")
  local has_diff, diff = pcall(require, "git_tools.diff")
  local active, picker = true, nil
  local function finish(apply)
    if not active then
      return
    end
    active = false
    callback(apply)
  end
  local items = {}
  for _, change in ipairs(plan.changes) do
    local before = plan.snapshots[change.path].lines
    local lines, sources
    if has_diff then
      lines, sources = diff.unified(before, change.lines, {
        old_path = change.path,
        ft = vim.filetype.match({ filename = change.path }),
      })
    else
      local patch = (vim.text and vim.text.diff or vim.diff)(
        table.concat(before, "\n") .. "\n",
        table.concat(change.lines, "\n") .. "\n",
        { result_type = "unified" }
      )
      lines = { "--- " .. change.path, "+++ " .. change.path }
      vim.list_extend(lines, vim.split(patch, "\n", { trimempty = true }))
    end
    items[#items + 1] = { text = change.path, lines = lines, sources = sources }
  end
  if #items == 0 then
    items[1] = { text = "Image move (no document edits)", lines = {}, message = true }
  end
  local header = {
    "Move: " .. plan.source,
    "To:   " .. plan.target,
    "",
    "Live buffers stay modified; unopened documents are saved.",
    "Only recognized references in the scanned project are updated.",
    "",
  }
  picker = selection.open({
    prompt = "Review image move · Enter to confirm · Esc to cancel",
    items = items,
    multi = false,
    resume = false,
    components = {
      require("selection_tools.components").path({
        get = function(item)
          return not item.message and item.text or nil
        end,
        path_format = false,
      }),
      require("selection_tools.components").text({
        get = function(item)
          return item.message and item.text or nil
        end,
      }),
    },
    format_item = function(item)
      return item.text
    end,
    preview = { enabled = true },
    previewer = function(ctx)
      local lines = vim.list_extend(vim.deepcopy(header), ctx.item.lines)
      if has_diff then
        return diff.render(ctx, lines, {
          backend = "native",
          title = "Image move",
          sources = ctx.item.sources,
          native = { file_header = false },
        }, function()
          return active
        end)
      end
      ctx.set_lines(lines, "diff", "Image move")
    end,
    on_choice = function(item)
      if not active then
        return
      end
      if not item then
        finish(false)
        return
      end
      -- Keep confirmation in the same UI framework without owning a split.
      picker = selection.select({ "Apply move", "Cancel" }, {
        prompt = string.format("Move image and update %d document(s)?", #plan.changes),
        resume = false,
      }, function(choice)
        finish(choice == "Apply move")
      end)
    end,
  })
  return {
    close = function()
      if not active then
        return
      end
      active = false
      if picker and not picker.closed then
        picker:close()
      end
    end,
  }
end

-- Reuse the native quickfix report/index contract and supply image previews.
function M.assets(render)
  return require("selection_tools").qflist({
    preview = {
      enabled = true,
      providers = {
        function(ctx)
          if not ctx.path or not require("image_tools.media.formats").supported(ctx.path) then
            return false
          end
          return preview(render)(ctx)
        end,
      },
    },
  })
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
