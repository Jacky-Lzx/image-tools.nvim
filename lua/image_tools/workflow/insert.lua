-- Module: image_tools.workflow.insert
--
-- Purpose:
--   Import or reference image files and insert format-specific markup as one
--   transaction.
--
-- Architecture:
--   Capture the originating document with an extmark, delegate rules to
--   document adapters and publish copies without overwriting existing files.
--   Runtime, clipboard and picker workflows reuse this service.
--
-- Ownership:
--   Each operation owns captured context, imported files and temporaries.
--   Cancellation or validation failure rolls back new files; successful text
--   insertion releases the mark and leaves assets available for undo.

local M = {}
local uv = vim.uv
local ns = vim.api.nvim_create_namespace("image_tools.insert")
local sequence = 0
local strategies = { "insert_after", "insert_before", "insert_line_after", "insert_line_before" }

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

function M.capture(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local cursor = opts.cursor or vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local strategy = opts.insert_strategy or "insert_line_after"
  assert(vim.tbl_contains(strategies, strategy), "Invalid insert_strategy")
  if strategy == "insert_after" then
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if col < #line then
      col = col + 1
      while col < #line and (line:byte(col + 1) or 0) >= 128 and line:byte(col + 1) < 192 do
        col = col + 1
      end
    end
  elseif strategy:find("line", 1, true) then
    col = 0
  end
  return {
    buf = buf,
    document = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    strategy = strategy,
    mark = vim.api.nvim_buf_set_extmark(buf, ns, row, col, { right_gravity = true }),
  }
end

function M.release(context)
  if context.mark and vim.api.nvim_buf_is_valid(context.buf) then
    pcall(vim.api.nvim_buf_del_extmark, context.buf, ns, context.mark)
  end
  context.mark = nil
end

local function valid(context)
  return context.mark
    and vim.api.nvim_buf_is_loaded(context.buf)
    and vim.bo[context.buf].modifiable
    and vim.api.nvim_buf_get_name(context.buf) == context.document
    and vim.bo[context.buf].filetype == context.filetype
end

M.relative = require("image_tools.document.paths").relative

function M.supported(filetype, path)
  local format = require("image_tools.document").adapter(filetype)
  return format ~= nil and format.supports_image(path)
end

function M.markup(path, alt, filetype)
  local format = assert(require("image_tools.document").adapter(filetype), "Unsupported image insertion filetype")
  return format.markup(path, alt)
end

-- One text edit gives a batch one undo entry. Never redirect an asynchronous
-- insertion to whichever window happens to be current when the prompt returns.
local function insert(context, snippets)
  assert(valid(context), "Source buffer was closed, renamed, changed filetype or made read-only")
  local pos = vim.api.nvim_buf_get_extmark_by_id(context.buf, ns, context.mark, {})
  assert(#pos == 2, "Insertion position was removed")
  local row, col = pos[1], pos[2]
  -- Separate this transaction from edits made while a UI prompt was open.
  vim.api.nvim_buf_call(context.buf, function()
    vim.cmd("let &g:undolevels = &g:undolevels")
  end)
  if context.strategy == "insert_line_before" or context.strategy == "insert_line_after" then
    if context.strategy == "insert_line_after" then
      row = row + 1
    end
    vim.api.nvim_buf_set_lines(context.buf, row, row, false, snippets)
  else
    vim.api.nvim_buf_set_text(context.buf, row, col, row, col, { table.concat(snippets, " ") })
  end
end

-- Import all resources before committing the text. Publishing uses link(2),
-- which cannot replace an existing destination even if another process races us.
function M.files(paths, opts, callback)
  opts = opts or {}
  callback = callback
    or function(err)
      if err and err ~= "Cancelled" then
        vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
      end
    end

  local context = opts.context or M.capture(opts)
  local state = { created = {}, temporaries = {}, outputs = {}, done = false }
  local function finish(err)
    if state.done then
      return
    end
    state.done = true
    if err then
      for _, path in ipairs(state.created) do
        uv.fs_unlink(path)
      end
    end
    for _, path in ipairs(state.temporaries) do
      uv.fs_unlink(path)
    end
    M.release(context)
    callback(err, not err and state.outputs or nil)
  end
  local cancel = function()
    finish("Cancelled")
  end
  local function fail(message)
    finish(tostring(message))
  end
  local format
  local ok, err = pcall(function()
    assert(valid(context), "Source buffer is not editable")
    format = assert(require("image_tools.document").adapter(context.filetype), "Unsupported image insertion filetype")
    assert(context.document ~= "", "Save the document before inserting images")
    assert(type(paths) == "table" and #paths > 0, "Choose at least one image file")
    assert(opts.mode == nil or opts.mode == "copy" or opts.mode == "reference", "mode must be copy or reference")
    for _, path in ipairs(paths) do
      assert(type(path) == "string" and path ~= "" and not path:find("[%z\r\n]"), "Invalid source path")
      assert(format.supports_image(path), "Unsupported image format for " .. context.filetype .. ": " .. path)
    end
  end)
  if not ok then
    fail(err)
    return cancel
  end
  local directory, base
  ok, err = pcall(function()
    local root = opts.root or vim.fs.dirname(context.document)
    if type(root) == "function" then
      root = root(context.document)
    end
    root = absolute(root)
    directory = opts.directory or "Figures"
    if type(directory) == "function" then
      directory = directory(context.document)
    end
    directory = directory:sub(1, 1) == "/" and absolute(directory) or absolute(root .. "/" .. directory)
    base = format.insertion_base(context.document, { root = opts.reference_root }, context.buf)
    base = absolute(base)
  end)
  if not ok then
    fail(err)
    return cancel
  end
  local index = 0
  local next_file
  next_file = function()
    if state.done then
      return
    end
    index = index + 1
    if index > #paths then
      local snippets = {}
      local success, message = pcall(function()
        for _, path in ipairs(state.outputs) do
          if format.validate_reference then
            format.validate_reference(path, context.document, { root = opts.reference_root }, context.buf)
          end
          snippets[#snippets + 1] = format.markup(M.relative(path, base), opts.alt)
        end
        insert(context, snippets)
      end)
      finish(not success and tostring(message) or nil)
      return
    end
    local source = absolute(paths[index])
    local stat = uv.fs_stat(source)
    if not stat or stat.type ~= "file" then
      fail("Image source is not a regular file: " .. source)
      return
    end
    if stat.size > (opts.max_bytes or 32 * 1024 * 1024) then
      fail("Image exceeds max_bytes: " .. source)
      return
    end
    if opts.mode == "reference" then
      state.outputs[#state.outputs + 1] = source
      next_file()
      return
    end
    local function save(name)
      if state.done then
        return
      end
      if name == nil then
        cancel()
        return
      end
      if name == "" or name == "." or name == ".." or name:find("[/\\%z\r\n]") then
        fail("Name must be a single filename")
        return
      end
      if format.sanitize_filename then
        name = format.sanitize_filename(name)
      end
      local extension = source:match("%.([^./]+)$")
      if not name:lower():match("%." .. extension:lower() .. "$") then
        name = name .. "." .. extension
      end
      local made, mkdir_err = pcall(vim.fn.mkdir, directory, "p")
      if not made then
        fail(mkdir_err)
        return
      end
      sequence = sequence + 1
      local temp = directory .. "/.image-tools-" .. uv.os_getpid() .. "-" .. sequence .. "-" .. uv.hrtime()
      state.temporaries[#state.temporaries + 1] = temp
      uv.fs_copyfile(
        source,
        temp,
        1,
        vim.schedule_wrap(function(copy_err)
          if state.done then
            uv.fs_unlink(temp)
            return
          end
          if copy_err then
            fail(copy_err)
            return
          end
          local after = uv.fs_stat(source)
          if
            not after
            or require("image_tools.media").key(source, stat) ~= require("image_tools.media").key(source, after)
          then
            fail("Image source changed during import")
            return
          end
          local stem = name:sub(1, #name - #extension - 1)
          local target
          for suffix = 0, 999 do
            local candidate = directory .. "/" .. stem .. (suffix == 0 and "" or "-" .. suffix) .. "." .. extension
            local linked, link_err, code = uv.fs_link(temp, candidate)
            if linked then
              target = candidate
              break
            end
            if code ~= "EEXIST" then
              fail(link_err)
              return
            end
          end
          if not target then
            fail("Too many filename collisions")
            return
          end
          state.created[#state.created + 1] = target
          state.outputs[#state.outputs + 1] = target
          uv.fs_unlink(temp)
          next_file()
        end)
      )
    end
    local name = opts.filename or vim.fs.basename(source)
    if opts.prompt_for_file_name then
      vim.ui.input({ prompt = "Image filename: ", default = name }, save)
    else
      save(name)
    end
  end
  vim.schedule(next_file)
  return cancel
end

return M
