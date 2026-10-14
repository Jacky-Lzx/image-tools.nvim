local M = {}

function M.base(document, opts, buf)
  local root = opts.root
  if type(root) == "function" then
    root = root(document)
  end
  if not root and buf and vim.tbl_contains({ "tex", "latex", "plaintex" }, vim.bo[buf].filetype) then
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

return M
