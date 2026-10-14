-- Module: image_tools.document.formats
--
-- Purpose:
--   Centralize supported document filetypes and adapter selection.
--
-- Architecture:
--   Map filetype aliases to Markdown, LaTeX or Typst and load the corresponding
--   adapter on demand. Document lookup, insertion and picker filtering share
--   this registry.
--
-- Ownership:
--   Keep a fixed alias table; adapters and their helpers own reference context
--   and validation behavior.

local M = {}
local aliases = { markdown = "markdown", tex = "tex", latex = "tex", plaintex = "tex", typst = "typst" }

-- Normalize supported filetypes to their canonical adapter kind.
---@param filetype string Neovim filetype.
---@return string? kind Nil for an unsupported filetype.
function M.kind(filetype)
  return aliases[filetype]
end

-- Load a supported adapter on demand, without making adapters depend on the dispatcher.
---@param filetype string Neovim filetype or alias.
---@return ImageToolsDocumentAdapter? adapter
function M.get(filetype)
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
