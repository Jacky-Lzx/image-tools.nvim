-- Module: image_tools.workflow.hash_worker (process entry point)
-- Purpose:
--   Hash binary images outside the editor without additional dependencies.
-- Architecture:
--   Run only in an isolated headless Neovim. Validate revisions around bounded
--   reads, then emit a digest; the parent validates the revision again on exit.
-- Ownership:
--   Own the descriptor and all bytes/encoding/SHA256 work. The parent queue
--   owns process cancellation and timeout. Never require this script in the editor.
local uv = vim.uv
local version = dofile(vim.fs.dirname(arg[0]) .. "/../media/file_version.lua")
local path, max_bytes = arg[1], tonumber(arg[2])
local fd
local ok, result = pcall(function()
  assert(path and max_bytes, "Expected image path and max_bytes")
  fd = assert(uv.fs_open(path, "r", 384))
  local before = assert(uv.fs_fstat(fd))
  assert(before.type == "file" and before.size <= max_bytes, "File is not regular or exceeds max_bytes")
  local chunks, offset = {}, 0
  while offset < before.size do
    local data = assert(uv.fs_read(fd, math.min(1024 * 1024, before.size - offset), offset))
    assert(#data > 0, "Unexpected end of file")
    chunks[#chunks + 1], offset = data, offset + #data
  end
  local after, current = assert(uv.fs_fstat(fd)), assert(uv.fs_stat(path))
  assert(
    version.key(path, before) == version.key(path, after) and version.key(path, before) == version.key(path, current),
    "File changed while hashing"
  )
  -- Base64 preserves NUL bytes across Vim's string boundary.
  return vim.fn.sha256(vim.base64.encode(table.concat(chunks)))
end)
if fd then
  uv.fs_close(fd)
end
if not ok then
  io.stderr:write(tostring(result) .. "\n")
  os.exit(1)
end
io.stdout:write(result .. "\n")
