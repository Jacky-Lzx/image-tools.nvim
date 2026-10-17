-- Module: image_tools.workflow.assets
--
-- Purpose:
--   Report missing references and possibly unused assets for a document or project.
-- Architecture:
--   Enumerate adapter-owned references, then inspect the document import directory.
--   Delegate project aggregation to asset_project. Never delete or rewrite resources.
-- Ownership:
--   Capture buffer identity and text version. Cancellation, rename, unload or text
--   changes suppress stale reports; pending filesystem callbacks retain no editor authority.
local M = {}
local uv = vim.uv

function M.check(opts, callback)
  if opts.scope == "project" then
    return require("image_tools.workflow.asset_project").check(opts, callback)
  end
  local buf = opts.buf and opts.buf ~= 0 and opts.buf or vim.api.nvim_get_current_buf()
  local original_name = vim.api.nvim_buf_get_name(buf)
  local document = opts._document_path or original_name
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local filetype = vim.bo[buf].filetype
  local adapter = require("image_tools.document.formats").get(opts._document_filetype or filetype)
  local kind = require("image_tools.document.formats").kind(opts._document_filetype or filetype)
  local active = true
  local report =
    { document = document, missing = {}, unreferenced = {}, scanned = 0, scope = "document", references = {} }
  local function current()
    return active
      and vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].filetype == filetype
      and vim.api.nvim_buf_get_name(buf) == original_name
      and vim.api.nvim_buf_get_changedtick(buf) == tick
      and require("image_tools.document.formats").get(opts._document_filetype or filetype) == adapter
  end
  local function done(err)
    if not active then
      return
    end
    active = false
    callback(err, not err and report or nil)
  end
  local function stale()
    if current() then
      return false
    end
    done("Document changed or unloaded during asset inspection")
    return true
  end
  local insertion = opts.insert or {}
  local ok, directory = pcall(function()
    assert(kind and document ~= "", "Save a supported document before checking assets")
    local base = insertion.root or vim.fs.dirname(document)
    if type(base) == "function" then
      base = base(document)
    end
    local dir = insertion.directory or "Figures"
    if type(dir) == "function" then
      dir = dir(document)
    end
    return vim.fs.normalize(vim.fn.fnamemodify(dir:sub(1, 1) == "/" and dir or base .. "/" .. dir, ":p"))
  end)
  if not ok then
    vim.schedule(function()
      done(tostring(directory))
    end)
    return function()
      active = false
    end
  end
  report.directory = directory
  local referenced = {}
  local cancel_enumeration
  local function inspect_directory()
    uv.fs_scandir(directory, function(err, scan)
      vim.schedule(function()
        if stale() then
          return
        end
        if err then
          if tostring(err):match("ENOENT") then
            done()
          else
            done(err)
          end
          return
        end
        local next_file
        next_file = function()
          if stale() then
            return
          end
          local name = uv.fs_scandir_next(scan)
          if not name then
            table.sort(report.unreferenced)
            done()
            return
          end
          local path = directory .. "/" .. name
          uv.fs_lstat(path, function(stat_err, stat)
            vim.schedule(function()
              if stale() then
                return
              end
              if not stat_err and stat.type == "file" and require("image_tools.media.formats").supported(path) then
                local key = uv.fs_realpath(path) or path
                if not referenced[key] then
                  report.unreferenced[#report.unreferenced + 1] = path
                end
              end
              next_file()
            end)
          end)
        end
        next_file()
      end)
    end)
  end
  cancel_enumeration = require("image_tools.document").enumerate(buf, opts, function(err, enumeration)
    if stale() then
      return
    end
    if err then
      done(err)
      return
    end
    report.scanned, report.truncated = enumeration.scanned, enumeration.truncated
    for _, item in ipairs(enumeration.references) do
      local ref = item.reference
      local location = { filename = document, lnum = ref.start_row, col = ref.start_col + 1 }
      if opts._capture_documents then
        location.reference = vim.deepcopy(ref)
      end
      if not opts._document_path then
        location.bufnr = buf
      end
      if item.path then
        local key = uv.fs_realpath(item.path) or item.path
        referenced[key] = true
        report.references[key] = report.references[key] or {}
        report.references[key][#report.references[key] + 1] = vim.deepcopy(location)
        local stat = uv.fs_stat(item.path)
        if not stat or stat.type ~= "file" then
          location.text = "Missing image: " .. item.path
          report.missing[#report.missing + 1] = location
        end
      elseif item.error and not item.error:match("^Remote image") then
        location.text = item.error
        report.missing[#report.missing + 1] = location
      end
    end
    if opts._references_only then
      done()
    else
      inspect_directory()
    end
  end)
  return function()
    active = false
    if cancel_enumeration then
      cancel_enumeration()
    end
  end
end
return M
