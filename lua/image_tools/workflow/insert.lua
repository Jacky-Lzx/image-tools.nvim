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

---@alias ImageToolsInsertCallback fun(err: string?, paths: string[]?)
---@class ImageToolsInsertContext
---@field buf integer Originating document buffer; asynchronous work never targets a replacement buffer.
---@field win integer Originating window; completion only moves the cursor while it is current.
---@field timestamp integer Local naming time captured before prompts or asynchronous work.
---@field document string Captured buffer filename used to detect rename and compute roots.
---@field filetype string Captured format used to detect filetype changes.
---@field strategy "insert_after"|"insert_before"|"insert_line_after"|"insert_line_before" Text transaction placement policy.
---@field mark? integer Origin extmark; cleared after success, failure or cancellation.
---@class ImageToolsInsertOptions
---@field directory? string|fun(document: string): string Import directory, relative to insertion root unless absolute.
---@field root? string|fun(document: string): string Asset copy base; separate from reference_root.
---@field reference_root? string|fun(document: string): string? Internal markup/project base supplied by Runtime root.
---@field mode? "copy"|"reference" File import policy; copy reuses sources already inside the import directory.
---@field deduplicate? boolean Reuse identical files of the same extension in the destination directory.
---@field filename? string Imported basename override; source extension is retained.
---@field file_name? string|function os.date format or naming function; file imports keep their names by default.
---@field alt? string Markdown/Typst image description.
---@field template? string|function|table|false Markup override, optionally indexed by filetype; false uses the adapter default.
---@field process? table|"select"|false Clipboard processing preset or selectable list; select uses built-ins.
---@field resize? string Internal selected ImageMagick geometry.
---@field command? string[] Internal selected custom converter argv with $INPUT/$OUTPUT.
---@field prompt_for_file_name? boolean Prompt for each imported basename.
---@field insert_strategy? string Text placement strategy; default insert_line_after.
---@field context? ImageToolsInsertContext Captured transaction context reused by prompt/clipboard/picker.
---@field buf? integer Explicit origin buffer for capture.
---@field cursor? integer[] One-based row and zero-based byte column for capture.
---@field max_bytes? integer Source/import compressed-byte limit.
---@field max_dimension? integer Clipboard PNG dimension limit.
---@field max_pixels? integer Clipboard PNG pixel-count limit.
---@field pngpaste? string Clipboard reader executable override.
---@field clipboard_timeout? integer Clipboard read timeout in milliseconds.
---@field format? "png"|"jpg"|"webp"|"avif" Clipboard format; default avif where supported, otherwise png.
---@field quality? number Clipboard conversion quality; default 75.
---@field magick? string Clipboard converter executable override.
---@field convert_timeout? integer Clipboard conversion process timeout.

---@class ImageToolsInsertion
local M = {}
local uv = vim.uv
local defaults = require("image_tools.defaults")
local UTF8_CONTINUATION_MIN = 0x80
local UTF8_CONTINUATION_MAX = 0xBF
local MAX_FILENAME_ATTEMPTS = 1000 -- Original basename plus numbered alternatives.
local COPYFILE_EXCL = 1 -- libuv: refuse to overwrite an existing temporary file.
local ns = vim.api.nvim_create_namespace("image_tools.insert")
local sequence = 0
local strategies = { "insert_after", "insert_before", "insert_line_after", "insert_line_before" }

local function markup(format, path, alt, filetype, opts, document)
  local text, offset = format.markup(path, alt)
  local name = vim.fs.basename(path)
  local stem = vim.fn.fnamemodify(name, ":r")
  return require("image_tools.workflow.template").render(opts and opts.template, {
    file_path = path,
    file_name = name,
    file_name_no_ext = stem,
    label = stem:lower():gsub("%s+", "-"),
    alt = alt or "",
    filetype = filetype,
    document = document,
  }, text, offset)
end

-- Normalize a resource path relative to the current working directory.
---@param path string Resource/import path.
---@return string absolute
local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

-- Record document identity and a gravity-aware extmark before any asynchronous user interaction.
---@param opts? ImageToolsInsertOptions Optional explicit buffer/cursor and strategy.
---@return ImageToolsInsertContext context
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
      while
        col < #line
        and (line:byte(col + 1) or 0) >= UTF8_CONTINUATION_MIN
        and line:byte(col + 1) <= UTF8_CONTINUATION_MAX
      do
        col = col + 1
      end
    end
  elseif strategy:find("line", 1, true) then
    col = 0
  end
  return {
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    timestamp = os.time(),
    document = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    strategy = strategy,
    mark = vim.api.nvim_buf_set_extmark(buf, ns, row, col, { right_gravity = true }),
  }
end

-- Remove the captured extmark if its buffer survives and invalidate further context use.
---@param context ImageToolsInsertContext Operation context.
---@return nil
function M.release(context)
  if context.mark and vim.api.nvim_buf_is_valid(context.buf) then
    pcall(vim.api.nvim_buf_del_extmark, context.buf, ns, context.mark)
  end
  context.mark = nil
end

-- Require the original loaded/modifiable buffer, filename, filetype and an unreleased mark.
---@param context ImageToolsInsertContext Captured document identity.
---@return boolean? valid Nil/false means invalid; readonly alone is not checked.
local function valid(context)
  return context.mark
    and vim.api.nvim_buf_is_loaded(context.buf)
    and vim.bo[context.buf].modifiable
    and vim.api.nvim_buf_get_name(context.buf) == context.document
    and vim.bo[context.buf].filetype == context.filetype
end

M.relative = require("image_tools.document.paths").relative

-- Ask the document adapter whether a filename is allowed for insertion.
---@param filetype string Target document filetype.
---@param opts? ImageToolsInsertOptions Optional template override.
---@param path string Source filename.
---@return boolean supported
function M.supported(filetype, path)
  local format = require("image_tools.document").adapter(filetype)
  return format ~= nil and format.supports_image(path)
end

-- Delegate escaped reference construction to the selected format adapter.
---@param path string Relative resource path.
---@param alt? string Image description.
---@param filetype string Target document filetype.
---@return string markup Unsupported formats/unsafe paths raise an error.
---@return integer? edit_offset Zero-based byte offset for editing, including newlines; defaults to the end.
function M.markup(path, alt, filetype, opts)
  local format = assert(require("image_tools.document").adapter(filetype), "Unsupported image insertion filetype")
  return markup(format, path, alt, filetype, opts)
end

-- One text edit gives a batch one undo entry. Never redirect an asynchronous
-- insertion to whichever window happens to be current when the prompt returns.
-- Validate captured authority and insert the ordered batch in its own undo block as one text edit.
---@param context ImageToolsInsertContext Origin identity, mark and strategy.
---@param snippets string[] Already validated adapter markup.
---@param edit_offset integer Zero-based byte offset within the first snippet, including newlines.
---@return nil
local function insert(context, snippets, edit_offset)
  assert(valid(context), "Source buffer was closed, renamed, changed filetype or made read-only")
  local pos = vim.api.nvim_buf_get_extmark_by_id(context.buf, ns, context.mark, {})
  assert(#pos == 2, "Insertion position was removed")
  local row, col = pos[1], pos[2]
  -- Separate this transaction from edits made while a UI prompt was open.
  vim.api.nvim_buf_call(context.buf, function()
    vim.cmd("let &g:undolevels = &g:undolevels")
  end)
  local linewise = context.strategy == "insert_line_before" or context.strategy == "insert_line_after"
  local lines = vim.split(table.concat(snippets, linewise and "\n" or " "), "\n", { plain = true })
  if linewise then
    col = 0
    if context.strategy == "insert_line_after" then
      row = row + 1
    end
    vim.api.nvim_buf_set_lines(context.buf, row, row, false, lines)
  else
    vim.api.nvim_buf_set_text(context.buf, row, col, row, col, lines)
  end
  -- An asynchronous import may finish after the user has moved to another
  -- window/document. Keep its text edit, but do not redirect their typing.
  if vim.api.nvim_get_current_win() == context.win and vim.api.nvim_get_current_buf() == context.buf then
    local prefix = vim.split(snippets[1]:sub(1, edit_offset), "\n", { plain = true })
    row = row + #prefix - 1
    col = (#prefix == 1 and col or 0) + #prefix[#prefix]
    local line = vim.api.nvim_buf_get_lines(context.buf, row, row + 1, false)[1]
    vim.api.nvim_win_set_cursor(context.win, { row + 1, col })
    vim.cmd(col == #line and "startinsert!" or "startinsert")
  end
end

-- Import all resources before committing the text. Publishing uses link(2),
-- which cannot replace an existing destination even if another process races us.
-- Validate the batch, publish copies/references in order, then commit markup or roll back newly
-- created assets.
---@param paths string[] At least one source path.
---@param opts? ImageToolsInsertOptions Import, context, prompt and reference policies.
---@param callback? ImageToolsInsertCallback Defaults to notifying actionable errors.
---@return ImageToolsCancel cancel Idempotent transaction cancellation; successful text undo keeps assets.
function M.files(paths, opts, callback)
  opts = opts or {}
  callback = callback
    or function(err)
      if err and err ~= "Cancelled" then
        vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
      end
    end

  local context = opts.context or M.capture(opts)
  -- Transaction-owned files are tracked separately from source/reference resources.
  ---@class ImageToolsImportState
  ---@field created string[] New published copies removed on failure, but retained after success.
  ---@field temporaries string[] Unpublished copies removed on every completion path.
  ---@field outputs string[] Ordered absolute resource paths used for the final text edit.
  ---@field done boolean Idempotent completion/cancellation guard.
  ---@type ImageToolsImportState
  local state = { created = {}, temporaries = {}, outputs = {}, done = false }
  -- Complete one transaction, roll back newly published files only on error and always release
  -- temporary/context state.
  ---@param err? string Failure/cancellation message; nil retains successfully imported files.
  ---@return nil
  local function finish(err)
    if state.done then
      return
    end
    state.done = true
    if state.cancel_content then
      state.cancel_content()
    end
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

  -- Cancelling uses the same rollback/completion path as validation or copy failure.
  ---@type ImageToolsCancel
  local cancel = function()
    finish("Cancelled")
  end

  -- Convert a validation/filesystem failure to the transaction error completion path.
  ---@param message any Error value to stringify.
  ---@return nil
  local function fail(message)
    finish(tostring(message))
  end
  local format
  local ok, err = pcall(function()
    assert(valid(context), "Source buffer is not editable")
    format = assert(require("image_tools.document").adapter(context.filetype), "Unsupported image insertion filetype")
    assert(context.document ~= "", "Save the document before inserting images")
    assert(type(paths) == "table" and #paths > 0, "Choose at least one image file")
    assert(opts.deduplicate == nil or type(opts.deduplicate) == "boolean", "deduplicate must be boolean")
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
  -- Advance only after the previous resource is published; text commits after the full batch.
  ---@return nil
  next_file = function()
    if state.done then
      return
    end
    index = index + 1
    if index > #paths then
      local snippets = {}
      local success, message = pcall(function()
        local edit_offset
        for _, path in ipairs(state.outputs) do
          if format.validate_reference then
            format.validate_reference(path, context.document, { root = opts.reference_root }, context.buf)
          end
          local snippet, offset =
            markup(format, M.relative(path, base), opts.alt, context.filetype, opts, context.document)
          if #snippets == 0 then
            edit_offset = offset or #snippet
          end
          snippets[#snippets + 1] = snippet
        end
        insert(context, snippets, edit_offset)
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
    if stat.size > (opts.max_bytes or defaults.max_bytes) then
      fail("Image exceeds max_bytes: " .. source)
      return
    end
    -- Resolve aliases before checking containment; a sibling with the same prefix
    -- is still an external import. Existing assets never become transaction-owned.
    local source_path, directory_path = uv.fs_realpath(source), uv.fs_realpath(directory)
    local already_imported = source_path
      and directory_path
      and vim.startswith(source_path, directory_path:gsub("/+$", "") .. "/")
    if opts.mode == "reference" or already_imported then
      state.outputs[#state.outputs + 1] = source
      next_file()
      return
    end

    -- Validate one basename and publish a copied file without overwriting collisions, then advance
    -- the batch.
    ---@param name? string Prompt result; nil cancels the transaction.
    ---@return nil
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
        COPYFILE_EXCL,
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
          local function publish(reused)
            if state.done then
              return
            end
            if reused then
              state.outputs[#state.outputs + 1] = reused
              uv.fs_unlink(temp)
              next_file()
              return
            end
            local stem = name:sub(1, #name - #extension - 1)
            local target
            for suffix = 0, MAX_FILENAME_ATTEMPTS - 1 do
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
          end
          if opts.deduplicate then
            state.cancel_content = require("image_tools.workflow.content").find(
              temp,
              directory,
              extension,
              opts.max_bytes or defaults.max_bytes,
              function(hash_err, reused)
                state.cancel_content = nil
                if state.done then
                  return
                end
                if hash_err then
                  fail(hash_err)
                else
                  publish(reused)
                end
              end
            )
          else
            publish()
          end
        end)
      )
    end
    local named, name = pcall(require("image_tools.workflow.naming").resolve, opts, {
      document = context.document,
      filetype = context.filetype,
      source = source,
      source_name = vim.fs.basename(source),
      extension = source:match("%.([^./]+)$"),
      kind = "file",
      timestamp = context.timestamp,
    })
    if not named then
      fail(name)
      return
    end
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
