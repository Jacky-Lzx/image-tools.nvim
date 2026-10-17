-- Module: image_tools.document.formats
--
-- Purpose:
--   Centralize supported document filetypes and adapter selection.
--
-- Architecture:
--   Load Markdown, LaTeX, Typst and HTML on demand, and normalize custom adapter
--   registrations. Lookup, insertion, picker filtering and project discovery
--   share this registry.
--
-- Ownership:
--   Keep built-ins protected. Custom registrations own normalized snapshots;
--   unregister closures remove only the registration that created them.

local M = {}
local aliases = { markdown = "markdown", tex = "tex", latex = "tex", plaintex = "tex", typst = "typst", html = "html" }
local extensions =
  { md = "markdown", markdown = "markdown", tex = "tex", ltx = "tex", typ = "typst", html = "html", htm = "html" }
local custom = {}
local generation = 0

function M.generation()
  return generation
end

function M.document_extensions()
  local result = vim.deepcopy(extensions)
  for ft, entry in pairs(custom) do
    for _, ext in ipairs(entry.extensions) do
      result[ext] = ft
    end
  end
  return result
end

function M.unregister(filetype)
  local existed = custom[filetype] ~= nil
  custom[filetype] = nil
  if existed then
    generation = generation + 1
  end
  return existed
end

function M.register(filetype, definition)
  assert(type(filetype) == "string" and filetype:match("^[%w_.%-]+$"), "Invalid adapter filetype")
  assert(not aliases[filetype], "Built-in adapters cannot be replaced; use insert.template to customize markup")
  assert(type(definition) == "table", "Adapter definition must be a table")
  local spec = vim.deepcopy(definition)
  assert(
    type(spec.markup) == "function" or type(spec.markup) == "string",
    "Adapter markup must be a function or template"
  )
  assert(
    type(spec.image_formats) == "table" and vim.islist(spec.image_formats) and #spec.image_formats > 0,
    "Adapter image_formats must be a nonempty list"
  )
  for _, ext in ipairs(spec.image_formats) do
    assert(
      type(ext) == "string" and ext:match("^%l+$") and require("image_tools.media.formats").supported("file." .. ext),
      "Unsupported adapter image format: " .. tostring(ext)
    )
  end
  local document_extensions = spec.file_extensions or (filetype:match("^[%l%d]+$") and { filetype } or {})
  assert(type(document_extensions) == "table" and vim.islist(document_extensions), "file_extensions must be a list")
  local occupied = M.document_extensions()
  for _, ext in ipairs(document_extensions) do
    assert(
      type(ext) == "string" and ext:match("^[%l%d]+$"),
      "file_extensions must be lowercase extensions without dots"
    )
    assert(not occupied[ext] or occupied[ext] == filetype, "Document extension already registered: " .. ext)
  end
  for _, hook in ipairs({
    "find",
    "references",
    "insertion_base",
    "sanitize_filename",
    "validate_reference",
    "path_edit",
  }) do
    assert(spec[hook] == nil or type(spec[hook]) == "function", "Adapter " .. hook .. " must be a function")
  end
  -- A markup-only adapter cannot enumerate references for project inspection.
  if not spec.references then
    document_extensions = {}
  end
  local adapter = {
    find = spec.find or function()
      return nil, "Preview lookup is not implemented for " .. filetype, "miss"
    end,
    references = function(buf, row, opts)
      assert(spec.references, "Reference enumeration is not implemented for " .. filetype)
      local refs = spec.references(buf, row, opts)
      assert(type(refs) == "table" and vim.islist(refs), "Adapter references must return a list")
      for _, item in ipairs(refs) do
        local ref = type(item) == "table" and item.reference
        assert(type(ref) == "table", "Adapter references need a reference range")
        assert(item.path == nil or type(item.path) == "string", "Adapter reference path must be a string")
        assert(item.error == nil or type(item.error) == "string", "Adapter reference error must be a string")
        assert(
          type(ref.start_col) == "number" and ref.start_col >= 0 and ref.start_col % 1 == 0,
          "Adapter reference start_col must be a byte column"
        )
        assert(
          type(ref.end_col) == "number" and ref.end_col >= 0 and ref.end_col % 1 == 0,
          "Adapter reference end_col must be a byte column"
        )
      end
      return refs
    end,
    image_formats = function()
      return vim.deepcopy(spec.image_formats)
    end,
    supports_image = function(path)
      return require("image_tools.media.formats").supports(path, spec.image_formats)
    end,
    insertion_base = spec.insertion_base or require("image_tools.document.paths").base,
    sanitize_filename = spec.sanitize_filename,
    validate_reference = spec.validate_reference,
    path_edit = spec.path_edit,
  }
  adapter.markup = function(path, alt)
    local text, offset
    if type(spec.markup) == "function" then
      text, offset = spec.markup(path, alt)
    else
      local name = vim.fs.basename(path)
      local stem = vim.fn.fnamemodify(name, ":r")
      text, offset = require("image_tools.workflow.template").render(spec.markup, {
        file_path = path,
        file_name = name,
        file_name_no_ext = stem,
        label = stem:lower():gsub("%s+", "-"),
        alt = alt or "",
        filetype = filetype,
      })
    end
    assert(
      type(text) == "string" and text ~= "" and not text:find("%z"),
      "Adapter markup must return nonempty text without NUL"
    )
    assert(
      offset == nil or type(offset) == "number" and offset % 1 == 0 and offset >= 0 and offset <= #text,
      "Adapter cursor offset is outside markup"
    )
    return text, offset
  end
  local entry = { adapter = adapter, extensions = document_extensions }
  custom[filetype] = entry
  generation = generation + 1
  return function()
    if custom[filetype] == entry then
      custom[filetype] = nil
      generation = generation + 1
      return true
    end
    return false
  end
end

-- Normalize supported filetypes to their canonical adapter kind.
---@param filetype string Neovim filetype.
---@return string? kind Nil for an unsupported filetype.
function M.kind(filetype)
  return aliases[filetype] or custom[filetype] and filetype
end

-- Load a supported adapter on demand, without making adapters depend on the dispatcher.
---@param filetype string Neovim filetype or alias.
---@return ImageToolsDocumentAdapter? adapter
function M.get(filetype)
  if custom[filetype] then
    return custom[filetype].adapter
  end
  local kind = M.kind(filetype)
  return kind and require("image_tools.document." .. kind) or nil
end

-- Test whether an alias exists without loading an adapter.
---@param filetype string Neovim filetype.
---@return boolean supported
function M.supported(filetype)
  return M.kind(filetype) ~= nil
end

return M
