-- Module: image_tools.workflow.content
--
-- Purpose:
--   Find byte-identical imports in one asset directory without blocking file reads.
-- Architecture:
--   Hash bounded files sequentially, checking revisions before/after reads. Filter
--   existing candidates by extension and size; skip symlinks and unreadable files.
-- Ownership:
--   Each request owns its descriptor and cancellation flag. Cancellation suppresses
--   delivery; outstanding filesystem callbacks still close their descriptors.
local M = {}
local uv = vim.uv
local version = require("image_tools.media.file_version")

function M.digest(path, max_bytes, callback)
  local active = true
  uv.fs_open(path, "r", 438, function(err, fd)
    if err then
      vim.schedule(function()
        if active then
          callback(err)
        end
      end)
      return
    end
    local function done(message, digest, stat)
      uv.fs_close(fd, function()
        vim.schedule(function()
          if active then
            callback(message, digest, stat)
          end
        end)
      end)
    end
    uv.fs_fstat(fd, function(stat_err, stat)
      if not active or stat_err or stat.type ~= "file" or stat.size > max_bytes then
        done(stat_err or "File is not regular or exceeds max_bytes")
        return
      end
      local chunks, offset = {}, 0
      local function read()
        if not active then
          done("Cancelled")
          return
        end
        if offset == stat.size then
          uv.fs_stat(path, function(after_err, after)
            if after_err or version.key(path, after) ~= version.key(path, stat) then
              done("File changed while hashing")
            else
              -- Base64 preserves all bytes across Vim's string boundary, including NUL.
              local data = table.concat(chunks)
              uv.fs_close(fd, function()
                vim.schedule(function()
                  if active then
                    callback(nil, vim.fn.sha256(vim.base64.encode(data)), stat)
                  end
                end)
              end)
            end
          end)
          return
        end
        uv.fs_read(fd, math.min(1024 * 1024, stat.size - offset), offset, function(read_err, data)
          if read_err or not data or #data == 0 then
            done(read_err or "Unexpected end of file")
            return
          end
          chunks[#chunks + 1], offset = data, offset + #data
          read()
        end)
      end
      read()
    end)
  end)
  return function()
    active = false
  end
end

function M.find(source, directory, extension, max_bytes, callback)
  local active, cancel_read = true, nil
  local function done(err, path)
    if active then
      callback(err, path)
    end
  end
  cancel_read = M.digest(source, max_bytes, function(err, hash, source_stat)
    if err then
      done(err)
      return
    end
    uv.fs_scandir(directory, function(scan_err, scan)
      vim.schedule(function()
        if not active then
          return
        end
        if scan_err then
          done(scan_err)
          return
        end
        local next_file
        next_file = function()
          if not active then
            return
          end
          local name = uv.fs_scandir_next(scan)
          if not name then
            done(nil)
            return
          end
          local path = directory .. "/" .. name
          if require("image_tools.media.formats").extension(path) ~= extension:lower() then
            vim.schedule(next_file)
            return
          end
          uv.fs_lstat(path, function(stat_err, stat)
            vim.schedule(function()
              if not active then
                return
              end
              if stat_err or stat.type ~= "file" or stat.size ~= source_stat.size then
                next_file()
                return
              end
              cancel_read = M.digest(path, max_bytes, function(_, candidate_hash)
                if candidate_hash == hash then
                  done(nil, path)
                else
                  next_file()
                end
              end)
            end)
          end)
        end
        next_file()
      end)
    end)
  end)
  return function()
    active = false
    if cancel_read then
      cancel_read()
    end
  end
end
return M
