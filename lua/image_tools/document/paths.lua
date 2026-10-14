-- Module: image_tools.document.paths
--
-- Purpose:
--   Resolve local image paths, document/project bases and relative references.
--
-- Architecture:
--   Shared by document adapters and insertion. Apply literal or Markdown
--   decoding, optional custom resolution and configured roots; LaTeX base
--   lookup can consult VimTeX when a buffer is supplied.
--
-- Ownership:
--   Keep no path cache: evaluate roots and resolvers on each call. Reject
--   remote schemes and invalid path bytes without fetching resources.

local M = {}

function M.base(document, opts, buf)
  local root = opts.root
  if type(root) == "function" then
    root = root(document)
  end
  if not root and buf and require("image_tools.document.formats").kind(vim.bo[buf].filetype) == "tex" then
    local vimtex = vim.b[buf].vimtex
    if type(vimtex) == "table" then
      root = vimtex.root
    end
  end
  return root and vim.fs.normalize(vim.fn.fnamemodify(root, ":p")) or vim.fs.dirname(document)
end

function M.resolve(src, document, opts)
  if not opts.literal then
    src = src:gsub("\\([%p ])", "%1")
  end
  -- Reject URLs before decoding, so percent escapes cannot hide a scheme.
  if src:match("^%a[%w+.-]*:") or src:sub(1, 2) == "//" then
    return nil, "Remote image references are not supported yet"
  end
  if not opts.literal then
    src = src:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  end
  if src:find("%z") or src:find("[\r\n]") then
    return nil, "Invalid image path"
  end
  if opts.resolve then
    local path = opts.resolve(document, src)
    if path then
      return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    end
  end
  if src:sub(1, 1) == "/" then
    return vim.fs.normalize(src)
  end
  if document == "" then
    return nil, "Save the document before previewing a relative image reference"
  end
  local base = M.base(document, opts)
  return vim.fs.normalize(base .. "/" .. src)
end

function M.relative(path, base)
  local a, b =
    vim.split(vim.fs.normalize(vim.fn.fnamemodify(path, ":p")), "/", { plain = true }),
    vim.split(vim.fs.normalize(vim.fn.fnamemodify(base, ":p")), "/", { plain = true })
  while a[1] and a[1] == b[1] do
    table.remove(a, 1)
    table.remove(b, 1)
  end
  return string.rep("../", #b) .. table.concat(a, "/")
end

return M
