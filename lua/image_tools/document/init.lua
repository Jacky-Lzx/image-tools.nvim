-- Module: image_tools.document
--
-- Purpose:
--   Dispatch document reference lookup through the canonical format adapters.
--
-- Architecture:
--   Use document/formats for filetype selection and enforce the scan ceiling
--   before lookup. Retain path helpers and the Markdown-line parse
--   compatibility API without making adapters import this dispatcher.
--
-- Ownership:
--   Own no syntax cache. at_cursor selects by byte column; at_line requests the
--   first covering reference, with parsing and resolution delegated to the
--   adapter.

---@class ImageToolsRange
---@field start_row integer One-based first covered buffer row.
---@field end_row integer One-based last covered buffer row, inclusive.
---@field start_col integer Zero-based byte column on the opening row, inclusive.
---@field end_col integer Zero-based byte column on the closing row, exclusive.
---@class ImageToolsReference
---@field src string Decoded literal source, before filesystem resolution.
---@field start_col integer Zero-based inclusive starting byte column.
---@field end_col integer Zero-based exclusive ending byte column.
---@field start_row? integer One-based row; omitted by legacy same-line parse helpers.
---@field end_row? integer Inclusive covered row; omitted by same-line parse helpers.
---@field directories? string[] LaTeX graphicspath context captured by a backend.
---@field kind? "math" Formula references carry TeX instead of a local asset.
---@field formula? string Complete standalone math expression with delimiters.
---@field path? string Logical content identity for formula references.
---@class ImageToolsDocumentAdapter
---@field find fun(buf: integer, row: integer, col: integer?, opts: table): string?, string?, string?, ImageToolsReference?
---@field references fun(buf: integer, row: integer, opts: table): table[] Resolved literal references opening on this row.
---@field image_formats fun(): string[] Insertion/picker extension list.
---@field supports_image fun(path: string): boolean Filename-based insertion capability.
---@field markup fun(path: string, alt: string?): string, integer? Reference text and optional editing byte offset.
---@field insertion_base fun(document: string, opts: table, buf: integer?): string Link base.
---@field sanitize_filename? fun(name: string): string Optional import-name sanitation.
---@field validate_reference? fun(path: string, document: string, opts: table, buf: integer?) Optional insertion boundary check.
---@alias ImageToolsLookupStatus "miss"|"pending"

---@class ImageToolsDocument
local M = {}

local paths = require("image_tools.document.paths")
local formats = require("image_tools.document.formats")
M.adapter = formats.get

-- Preserve the existing document helpers while format modules use paths directly.
M.base, M.resolve = paths.base, paths.resolve

-- Retain the legacy Markdown-line parser; format-specific buffer lookup uses adapter dispatch.
---@param line string One complete source line.
---@return ImageToolsReference[] references
function M.parse(line)
  return require("image_tools.document.markdown").parse(line)
end

-- Check whether a document filetype has an adapter.
---@param filetype string Neovim filetype or supported alias.
---@return boolean supported
function M.supported(filetype)
  return formats.supported(filetype)
end

-- Enforce filetype/scan limits and delegate to the selected adapter; do not render or prepare
-- pixels.
---@param buf integer Buffer id.
---@param row integer One-based buffer row.
---@param col? integer Zero-based byte column; nil requests the first covering reference.
---@param opts ImageToolsOptions Lookup/scan/root settings.
---@return string? path Resolved image source.
---@return string? error Lookup/resolution message on failure.
---@return ImageToolsLookupStatus? status Only miss permits cursor-to-line fallback; pending must wait.
---@return ImageToolsReference? reference Selected range when resolved, or pending LaTeX coverage.
local function find(buf, row, col, opts)
  local filetype = vim.bo[buf].filetype
  local format = formats.get(filetype)
  if not format then
    return nil, "Image references support Markdown, LaTeX and Typst"
  end
  if row > opts.max_scan_lines then
    return nil, "Document exceeds max_scan_lines; use :ImagePreview with a file path"
  end
  local path, err, status, reference = format.find(buf, row, col, opts)
  if status == "pending" or col ~= nil and reference then
    return path, err, status, reference
  end
  local math = require("image_tools.document.math")
  local formula = math.find(buf, row, col, opts)
  if
    formula
    and (
      not reference
      or formula.start_row < reference.start_row
      or formula.start_row == reference.start_row and formula.start_col < reference.start_col
    )
  then
    return formula.path, nil, nil, formula
  end
  if not path and not reference and col ~= nil and math.find(buf, row, nil, opts) then
    return nil, "No image or formula under the cursor", "miss"
  end
  return path, err, status, reference
end

-- Select a reference whose byte-column range covers the cursor, retaining selected-path errors.
---@param buf integer Buffer id.
---@param row integer One-based row.
---@param col integer Zero-based byte column.
---@param opts ImageToolsOptions Lookup settings.
---@return string? path Resolved image source.
---@return string? error Lookup/resolution message on failure.
---@return ImageToolsLookupStatus? status Only miss permits cursor-to-line fallback; pending must wait.
---@return ImageToolsReference? reference Selected range when resolved, or pending LaTeX coverage.
function M.at_cursor(buf, row, col, opts)
  return find(buf, row, col, opts)
end

-- A line with multiple references consistently previews its first image.
-- Request the first covering reference regardless of horizontal cursor position.
---@param buf integer Buffer id.
---@param row integer One-based row.
---@param opts ImageToolsOptions Lookup settings.
---@return string? path Resolved image source.
---@return string? error Lookup/resolution message on failure.
---@return ImageToolsLookupStatus? status Only miss permits cursor-to-line fallback; pending must wait.
---@return ImageToolsReference? reference Selected range when resolved, or pending LaTeX coverage.
function M.at_line(buf, row, opts)
  return find(buf, row, nil, opts)
end

-- Enumerate adapter-owned references in scheduled batches without changing editor focus.
-- Offline inspection uses an unnamed scratch buffer plus private path/filetype overrides.
function M.enumerate(buf, opts, callback)
  opts = vim.tbl_extend("keep", opts or {}, { max_scan_lines = require("image_tools.defaults").max_scan_lines })
  local active, row = true, 1
  local name, tick, ft = vim.api.nvim_buf_get_name(buf), vim.api.nvim_buf_get_changedtick(buf), vim.bo[buf].filetype
  local adapter = formats.get(opts._document_filetype or ft)
  local count = vim.api.nvim_buf_line_count(buf)
  local limit = math.min(count, opts.max_scan_lines)
  local report = { references = {}, scanned = 0, truncated = count > limit }
  local step
  local function done(err)
    active = false
    callback(err, not err and report or nil)
  end
  step = function()
    if not active then
      return
    end
    if not adapter then
      done("Unsupported document filetype")
      return
    end
    if
      not vim.api.nvim_buf_is_valid(buf)
      or not vim.api.nvim_buf_is_loaded(buf)
      or vim.api.nvim_buf_get_name(buf) ~= name
      or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      or vim.bo[buf].filetype ~= ft
    then
      done("Document changed or unloaded during reference enumeration")
      return
    end
    for _ = 1, 20 do
      if row > limit then
        done()
        return
      end
      local ok, refs = pcall(adapter.references, buf, row, opts)
      if not ok then
        done(tostring(refs))
        return
      end
      vim.list_extend(report.references, refs)
      report.scanned, row = row, row + 1
    end
    vim.schedule(step)
  end
  vim.schedule(step)
  return function()
    active = false
  end
end

return M
