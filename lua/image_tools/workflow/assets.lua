-- Module: image_tools.workflow.assets
--
-- Purpose:
--   Report missing image references and possibly unused assets for one document.
-- Architecture:
--   Probe adapter-selected references in scheduled batches, then inspect regular
--   files in the configured import directory. Never delete or rewrite resources.
-- Ownership:
--   Capture buffer identity and text version. Cancellation, rename, unload or text
--   changes suppress stale reports; pending filesystem callbacks retain no editor authority.
local M = {}
local uv = vim.uv

function M.check(opts, callback)
  local buf = opts.buf and opts.buf ~= 0 and opts.buf or vim.api.nvim_get_current_buf()
  local document = vim.api.nvim_buf_get_name(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local filetype = vim.bo[buf].filetype
  local kind = require("image_tools.document.formats").kind(filetype)
  local active = true
  local report = { document = document, missing = {}, unreferenced = {}, scanned = 0 }
  local function current()
    return active
      and vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].filetype == filetype
      and vim.api.nvim_buf_get_name(buf) == document
      and vim.api.nvim_buf_get_changedtick(buf) == tick
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
    assert(kind and document ~= "", "Save a Markdown, LaTeX or Typst document before checking assets")
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
  local referenced, row = {}, 1
  local count = vim.api.nvim_buf_line_count(buf)
  local limit = math.min(count, opts.max_scan_lines)
  report.truncated = count > limit
  local lookup = vim.tbl_extend("force", opts, { treesitter = false })
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
  local step
  step = function()
    if stale() then
      return
    end
    for _ = 1, 20 do
      if row > limit then
        inspect_directory()
        return
      end
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      local columns = {}
      if kind == "markdown" then
        for _, image in ipairs(require("image_tools.document.markdown").parse(line, true)) do
          columns[#columns + 1] = image.start_col
        end
      else
        local pattern = kind == "tex" and "\\includegraphics" or "image%s*%("
        local pos = 1
        while pos <= #line do
          local start, finish = line:find(pattern, pos, kind == "tex")
          if not start then
            break
          end
          columns[#columns + 1], pos = start - 1, finish + 1
        end
      end
      for _, col in ipairs(columns) do
        local path, err = require("image_tools.document").at_cursor(buf, row, col, lookup)
        if path then
          referenced[uv.fs_realpath(path) or path] = true
          local stat = uv.fs_stat(path)
          if not stat or stat.type ~= "file" then
            report.missing[#report.missing + 1] =
              { bufnr = buf, lnum = row, col = col + 1, text = "Missing image: " .. path }
          end
        elseif
          err
          and (err:match("^Undefined image") or err:match("^Image not found") or err:match("^Invalid image path"))
        then
          report.missing[#report.missing + 1] = { bufnr = buf, lnum = row, col = col + 1, text = err }
        end
      end
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
