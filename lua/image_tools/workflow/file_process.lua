-- Transform external file imports before a single transactional publication.
-- Existing assets and reference mode preserve their original reuse semantics.
local M = {}
local uv = vim.uv
local defaults = require("image_tools.defaults")
local media_formats = require("image_tools.media.formats")
local process = require("image_tools.workflow.process")
local version = require("image_tools.media.file_version")

function M.files(paths, opts, callback)
  local I = require("image_tools.workflow.insert")
  local context = opts.context or I.capture(opts)
  local done, temporary, cancel_work, cancel_import = false, nil, nil, nil
  local function cleanup()
    if temporary then
      vim.fn.delete(temporary, "rf")
    end
  end
  local function finish(err, outputs)
    if done then
      cleanup()
      return
    end
    done = true
    cleanup()
    I.release(context)
    if callback then
      callback(err, outputs)
    elseif err and err ~= "Cancelled" then
      vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
    end
  end
  local function cancel()
    if done then
      return
    end
    if cancel_work then
      cancel_work()
    end
    if cancel_import then
      cancel_import()
    end
    finish("Cancelled")
  end
  local sources, reuse, revisions, prepared = {}, {}, {}, {}
  local ok, err = pcall(function()
    process.validate(opts.process)
    assert(context.document ~= "" and context.adapter, "Save a supported document before importing images")
    assert(type(paths) == "table" and #paths > 0, "Choose at least one image file")
    local root = opts.root or vim.fs.dirname(context.document)
    if type(root) == "function" then
      root = root(context.document)
    end
    local directory = opts.directory or "Figures"
    if type(directory) == "function" then
      directory = directory(context.document)
    end
    directory = directory:sub(1, 1) == "/" and directory or root .. "/" .. directory
    directory = uv.fs_realpath(directory)
    for index, path in ipairs(paths) do
      assert(type(path) == "string" and not path:find("[%z\r\n]"), "Invalid image source")
      path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
      local stat = assert(uv.fs_stat(path), "Image source does not exist: " .. path)
      assert(
        stat.type == "file" and stat.size <= (opts.max_bytes or defaults.max_bytes),
        "Invalid/oversized image source"
      )
      assert(media_formats.supported(path), "Unsupported source image format")
      local realpath = uv.fs_realpath(path)
      sources[index], revisions[index] = path, version.key(path, stat)
      reuse[index] = directory and realpath and vim.startswith(realpath, directory:gsub("/+$", "") .. "/") or false
    end
  end)
  if not ok then
    finish(tostring(err))
    return cancel
  end
  local function publish()
    for index, path in ipairs(sources) do
      local stat = uv.fs_stat(path)
      if not stat or version.key(path, stat) ~= revisions[index] then
        finish("Image source changed during processing")
        return
      end
    end
    cancel_import = I.files(
      prepared,
      vim.tbl_extend("force", opts, { context = context, process = false, _sources = sources }),
      finish
    )
  end
  if not vim.tbl_contains(reuse, false) then
    cancel_import = I.files(sources, vim.tbl_extend("force", opts, { context = context, process = false }), finish)
    return cancel
  end
  local function selected(preset)
    if done then
      return
    end
    if not preset then
      finish("Cancelled")
      return
    end
    local options = vim.tbl_extend("force", opts, preset)
    local format = options.format or "png"
    temporary = assert(uv.fs_mkdtemp(vim.fn.tempname() .. "-image-tools-process-XXXXXX"))
    local index = 0
    local next_file
    next_file = function()
      if done then
        return
      end
      index = index + 1
      if index > #sources then
        publish()
        return
      end
      if reuse[index] then
        prepared[index] = sources[index]
        next_file()
        return
      end
      -- Private input names avoid ImageMagick's filename/scene interpretation.
      local input = temporary .. "/input-" .. index .. "." .. media_formats.extension(sources[index])
      local output = temporary .. "/output-" .. index .. "." .. format
      uv.fs_copyfile(
        sources[index],
        input,
        1,
        vim.schedule_wrap(function(copy_err)
          if done then
            cleanup()
            return
          end
          if copy_err then
            finish(tostring(copy_err))
            return
          end
          local success, command = pcall(process.command, options, input .. (options.command and "" or "[0]"), output)
          if not success then
            finish(tostring(command))
            return
          end
          cancel_work = require("image_tools.media.conversion_queue").run(
            command,
            { timeout = opts.convert_timeout or defaults.convert_timeout },
            function(result)
              cancel_work = nil
              if done then
                cleanup()
                return
              end
              if result.code ~= 0 then
                finish("Image processing failed: " .. vim.trim(result.stderr or ""))
                return
              end
              local stat = uv.fs_stat(output)
              if not stat or stat.size == 0 or stat.size > (opts.max_bytes or defaults.max_bytes) then
                finish("Processed image missing or exceeds max_bytes")
                return
              end
              -- Decode metadata to reject wrong encodings, invalid outputs and oversized rasters.
              cancel_work = require("image_tools.media.conversion_queue").run(
                { opts.magick or "magick", "identify", "-format", "%m %w %h", output },
                { timeout = opts.convert_timeout or defaults.convert_timeout, text = true },
                function(identified)
                  cancel_work = nil
                  if done then
                    cleanup()
                    return
                  end
                  local encoding, width, height = (identified.stdout or ""):match("^(%u+) (%d+) (%d+)$")
                  local expected = ({ jpg = "JPEG", png = "PNG", webp = "WEBP", avif = "AVIF" })[format]
                  width, height = tonumber(width), tonumber(height)
                  if
                    identified.code ~= 0
                    or encoding ~= expected
                    or not width
                    or not height
                    or width < 1
                    or height < 1
                    or width > (opts.max_dimension or defaults.max_dimension)
                    or height > (opts.max_dimension or defaults.max_dimension)
                    or width * height > (opts.max_pixels or defaults.max_pixels)
                  then
                    finish("Processed image has invalid encoding or exceeds dimension limits")
                    return
                  end
                  prepared[index] = output
                  next_file()
                end
              )
            end
          )
        end)
      )
    end
    next_file()
  end
  ok, err =
    pcall(process.select, opts.process, context.filetype, opts.format or "png", selected, "Imported image processing:")
  if not ok then
    finish(tostring(err))
  end
  return cancel
end

return M
