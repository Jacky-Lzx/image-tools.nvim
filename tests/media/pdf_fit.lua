vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local media = require("image_tools.media")
local pdf = require("image_tools.media.pdf")
local tmp = assert(vim.env.IMAGE_TOOLS_TEST_TMP) .. "/pdf-fit"
vim.fn.mkdir(tmp, "p")
local source = tmp .. "/cropped.pdf"
assert(vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.pdf", source))
local checks, launches = 0, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function await(fn)
  check(vim.wait(10000, fn, 2), "PDF fit completes")
end
local options = require("image_tools.config").resolve({ cache = tmp .. "/cache" })
local system = vim.system
vim.system = function(command, ...)
  if command[1] == "magick" then
    launches = launches + 1
  end
  return system(command, ...)
end
local results, completed = {}, 0
local releases = {}
for index, target in ipairs({ { width = 2000, height = 1000 }, { width = 4000, height = 2000 } }) do
  releases[index] = media.prepare(
    source,
    vim.tbl_extend("force", options, { _raster_size = target }),
    function(err, image)
      check(not err, err)
      results[index] = image
      completed = completed + 1
    end
  )
end
await(function()
  return completed == 2
end)
check(results[1].width == 1600 and results[1].height == 1000, "Small cropped PDF fills requested pixels")
check(results[2].width == 3200 and results[2].height == 2000, "Larger viewport increases raster detail")
check(results[1].path ~= results[2].path and launches == 2, "Different pixel targets have independent conversions")
local before, cached = launches, nil
media.prepare(
  source,
  vim.tbl_extend("force", options, { _raster_size = { width = 2000, height = 1000 } }),
  function(err, image)
    check(not err, err)
    cached = image
  end
)
await(function()
  return cached ~= nil
end)
check(launches == before and cached.path == results[1].path, "Matching targets reuse cached raster pixels")
local limited
media.prepare(
  source,
  vim.tbl_extend(
    "force",
    options,
    { _raster_size = { width = 4000, height = 2000 }, max_dimension = 1000, max_pixels = 200000 }
  ),
  function(err, image)
    check(not err, err)
    limited = image
  end
)
await(function()
  return limited ~= nil
end)
check(
  limited.width <= 1000 and limited.height <= 1000 and limited.width * limited.height <= 200000,
  "Adaptive rasterization obeys dimension and pixel budgets"
)
-- A mixed-size PDF with a rotated first page catches document-wide geometry mistakes.
local objects = {
  "<< /Type /Catalog /Pages 2 0 R >>",
  "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
  "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 160 100] /CropBox [0 0 80 100] /Rotate 90 /Resources << >> /Contents 5 0 R >>",
  "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << >> /Contents 5 0 R >>",
  "<< /Length 0 >>\nstream\n\nendstream",
}
local data, offsets = "%PDF-1.4\n", {}
for index, object in ipairs(objects) do
  offsets[index] = #data
  data = data .. index .. " 0 obj\n" .. object .. "\nendobj\n"
end
local xref = #data
data = data .. "xref\n0 6\n0000000000 65535 f \n"
for _, offset in ipairs(offsets) do
  data = data .. string.format("%010d 00000 n \n", offset)
end
data = data .. "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" .. xref .. "\n%%EOF\n"
local mixed = tmp .. "/mixed.pdf"
local fd = assert(vim.uv.fs_open(mixed, "w", 420))
assert(vim.uv.fs_write(fd, data, 0))
vim.uv.fs_close(fd)
local pages = {}
for page = 1, 2 do
  media.prepare(
    mixed,
    vim.tbl_extend("force", options, { page = page, _raster_size = { width = 2000, height = 1000 } }),
    function(err, image)
      check(not err, err)
      pages[page] = image
    end
  )
end
await(function()
  return pages[1] and pages[2]
end)
check(pages[1].width == 625 and pages[1].height == 1000, "Rotation is included in selected-page dimensions")
check(pages[2].width == 750 and pages[2].height == 1000, "Each page uses its own dimensions")
local page_size, callback, cancelled = pdf.page_size, nil, 0
pdf.page_size = function(_, _, receive)
  callback = receive
  return function()
    cancelled = cancelled + 1
  end
end
local delivered = false
local cancel = media.prepare(
  source,
  vim.tbl_extend("force", options, {
    _raster_size = { width = 2100, height = 1000 },
  }),
  function()
    delivered = true
  end
)
await(function()
  return callback ~= nil
end)
cancel()
callback(nil, { width = 160, height = 100 })
vim.wait(20)
check(
  cancelled == 1 and not delivered and require("image_tools.media.prepare").status().pending_jobs == 0,
  "Closing during metadata lookup cancels work and suppresses late delivery"
)
callback = nil
local changed_error
media.prepare(
  source,
  vim.tbl_extend("force", options, {
    _raster_size = { width = 2200, height = 1000 },
  }),
  function(err)
    changed_error = err
  end
)
await(function()
  return callback ~= nil
end)
local stat = assert(vim.uv.fs_stat(source))
assert(vim.uv.fs_utime(source, stat.atime.sec, stat.mtime.sec + 5))
callback(nil, { width = 160, height = 100 })
await(function()
  return changed_error ~= nil
end)
check(changed_error:find("source changed", 1, true), "Source changes during metadata lookup reject the render")
pdf.page_size, vim.system = page_size, system
for _, release in ipairs(releases) do
  release()
end
print("adaptive PDF: " .. checks .. " assertions passed")

-- External floats must reach the same pixel-fit preparation as embedded panes.
vim.o.columns, vim.o.lines = 100, 40
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function() end,
  request = function(_, _, _, receive)
    receive(nil)
    return function() end
  end,
}
local tools = require("image_tools")
tools.setup(vim.tbl_extend("force", options, { auto_preview = false }))
local float = assert(tools.float({ path = source }))
await(function()
  return float:status().stage == "ready"
end)
check(
  float.preview.state.image_width == 1216 and float.preview.state.image_height == 760,
  "External PDF float prepares viewport-sized pixels instead of the 320x200 fixed-DPI raster"
)
local width, height =
  vim.api.nvim_win_get_width(float.preview.state.win), vim.api.nvim_win_get_height(float.preview.state.win)
float:close()
float = assert(tools.float({ path = source, render_scale = 1 }))
await(function()
  return float:status().stage == "ready"
end)
check(
  float.preview.state.image_width == 640 and float.preview.state.image_height == 400,
  "Explicit sampling selects a separate raster"
)
check(
  vim.api.nvim_win_get_width(float.preview.state.win) == width
    and vim.api.nvim_win_get_height(float.preview.state.win) == height,
  "Sampling changes sharpness without changing float geometry"
)
float:close()
float = assert(tools.float({ path = source, fit_pixels = false }))
await(function()
  return float:status().stage == "ready"
end)
check(
  float.preview.state.image_width == 320 and float.preview.state.image_height == 200,
  "Explicit opt-out retains configured fixed DPI"
)
float:close()
tools.clear_cache()
print("PDF external float: viewport rasterization, sampling, geometry and opt-out passed")
