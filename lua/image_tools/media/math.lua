-- Module: image_tools.media.math
--
-- Purpose:
--   Compile standalone TeX formulas to validated transparent PNGs.
--
-- Architecture:
--   Run latex and dvipng through the shared conversion queue in a private job
--   directory. Cache by source, preamble, tools, DPI and resolved text color.
--
-- Ownership:
--   Own the process cancellation, temporary workspace and worker disk lease.
--   media/prepare coalesces subscribers and retains delivered output leases.

local M = {}
local uv = vim.uv
local disk = require("image_tools.media.disk_cache")
local png = require("image_tools.media.png")
local DISPLAY_DENSITY = 180 -- Keep formula sizing independent of raster sampling density.

-- Resolve the foreground when requested, so theme changes select new pixels.
local function foreground(opts)
  local value = opts.math.foreground
  if value == "auto" then
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    value = string.format("#%06x", normal.fg or (vim.o.background == "dark" and 0xffffff or 0x000000))
  end
  return value
end

function M.key(opts)
  local math = opts.math
  return vim.fn.sha256(table.concat({
    "formula-v1",
    opts._formula,
    math.preamble,
    math.latex,
    math.dvipng,
    tostring(math.density),
    foreground(opts),
  }, "\0"))
end

---@param path string Logical formula identity, not a filesystem path.
---@param opts ImageToolsOptions Includes the complete selected _formula source.
---@param callback ImageToolsImageCallback
---@param metadata_only? boolean
---@return ImageToolsCancel cancel
function M.prepare(path, opts, callback, metadata_only)
  local color = foreground(opts)
  local cancelled, process, workspace, lease, timing = false, nil, nil, nil, nil
  local output = opts.cache .. "/" .. M.key(opts) .. ".png"
  local function cleanup()
    if workspace then
      vim.fn.delete(workspace, "rf")
    end
  end
  local function release()
    if lease then
      lease()
      lease = nil
    end
  end
  local function done(err, image)
    cleanup()
    if not cancelled then
      if image then
        image.source, image.cache_source = path, path
        image.display_size = {
          width = math.max(1, math.floor(image.width * DISPLAY_DENSITY / opts.math.density + 0.5)),
          height = math.max(1, math.floor(image.height * DISPLAY_DENSITY / opts.math.density + 0.5)),
        }
      end
      callback(err, image, timing)
    end
    release()
  end
  local function read()
    png.read(output, opts, done, metadata_only)
  end
  local function run(command, next_step)
    process = require("image_tools.media.conversion_queue").run(command, {
      cwd = workspace,
      text = true,
      timeout = opts.convert_timeout,
      env = { openin_any = "p", openout_any = "p" },
    }, function(result)
      process = nil
      if cancelled then
        cleanup()
        return
      end
      if timing then
        timing.finished = result.timing.finished
      else
        timing = result.timing
      end
      if result.code ~= 0 then
        local detail = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
        -- TeX logs can be large; retain a useful bounded error in ImageInfo.
        done("Formula rendering failed (" .. vim.fs.basename(command[1]) .. "): " .. detail:sub(-4096))
        return
      end
      next_step()
    end)
  end
  vim.schedule(function()
    if cancelled then
      return
    end
    if #opts._formula > opts.math.max_bytes then
      done("Formula exceeds math.max_bytes")
      return
    end
    lease = disk.acquire(opts, output, function()
      if cancelled then
        return
      end
      if uv.fs_stat(output) then
        read()
        return
      end
      for _, name in ipairs({ "latex", "dvipng" }) do
        if vim.fn.executable(opts.math[name]) ~= 1 then
          done("Formula rendering requires " .. opts.math[name] .. " (configure math." .. name .. ")")
          return
        end
      end
      vim.fn.mkdir(opts.cache, "p")
      workspace = vim.fn.tempname() .. "-image-tools-math"
      local ok, err = pcall(function()
        assert(uv.fs_mkdir(workspace, 448)) -- Private 0700 workspace, independent of the source document.
        local source = table.concat({
          "\\documentclass{article}",
          opts.math.preamble,
          "\\pagestyle{empty}",
          "\\begin{document}",
          "\\noindent",
          opts._formula,
          "\\end{document}",
        }, "\n")
        vim.fn.writefile(vim.split(source, "\n", { plain = true }), workspace .. "/formula.tex")
      end)
      if not ok then
        done("Cannot create formula workspace: " .. tostring(err))
        return
      end
      run(
        { opts.math.latex, "-no-shell-escape", "-interaction=nonstopmode", "-halt-on-error", "formula.tex" },
        function()
          local rgb = {}
          for component in color:gmatch("%x%x") do
            rgb[#rgb + 1] = string.format("%.6f", tonumber(component, 16) / 255)
          end
          local temporary = workspace .. "/formula.png"
          run({
            opts.math.dvipng,
            "--nogs",
            "--norawps",
            "-T",
            "tight",
            "-D",
            tostring(opts.math.density),
            "-bg",
            "Transparent",
            "-fg",
            "rgb " .. table.concat(rgb, " "),
            "-p",
            "1",
            "-l",
            "1",
            "-o",
            temporary,
            "formula.dvi",
          }, function()
            png.read(temporary, opts, function(read_err, image)
              if cancelled then
                cleanup()
                return
              end
              if read_err then
                done(read_err)
                return
              end
              -- Workspaces may live on another filesystem; copy into a private
              -- staging file beside the destination before atomic publication.
              local staging = output .. "." .. tostring(uv.hrtime()) .. ".tmp.png"
              local copied, copy_err = uv.fs_copyfile(temporary, staging)
              local renamed, rename_err
              if copied then
                renamed, rename_err = uv.fs_rename(staging, output)
              end
              uv.fs_unlink(staging)
              if not renamed then
                done(tostring(copy_err or rename_err))
                return
              end
              image.path = output
              image.key = require("image_tools.media.file_version").key(output, assert(uv.fs_stat(output)))
              disk.published(opts, output)
              done(nil, image)
            end, metadata_only)
          end)
        end
      )
    end)
  end)
  return function()
    cancelled = true
    if process then
      process()
    end
    cleanup()
    release()
  end
end

return M
