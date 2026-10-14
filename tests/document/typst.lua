vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local T, D, I =
  require("image_tools.document.typst"), require("image_tools.document"), require("image_tools.workflow.insert")
local tmp = vim.env.IMAGE_TOOLS_TEST_TMP .. "/typst"
vim.fn.mkdir(tmp, "p")
tmp = assert(vim.uv.fs_realpath(tmp))
local count = 0
local function check(value, msg)
  count = count + 1
  assert(value, msg)
end
local function scan(lines, expected, message)
  check(#T.scan(lines) == expected, message)
end
scan({ [[#image("x.png", width: 50%)]] }, 1, "Basic call")
scan({ [[#figure(image("x.png"), caption: [test])]] }, 1, "Nested image")
scan({ [[#figure(]], [[image("x.png"),]], [[caption: [ignored])]] }, 0, "Reference only on current line")
scan({ [[#figure(]], [[image("x.png"),]] }, 1, "Multiline figure with same-line image call")
scan({ [[#let img = image("x.png")]] }, 1, "Let expression")
scan({ [[text image("x.png")]] }, 0, "Markup text is not an image call")
scan({ [[#let x = "#image(\"fake.png\")"]] }, 0, "Code strings excluded")
scan({ [[#let x = "multiline]], [[#image(\"fake.png\")"]] }, 0, "Multiline strings excluded")
scan({ [[`#image("x.png")`]] }, 0, "Inline raw excluded")
scan({ [[```typst]], [[#image("x.png")]], [[```]], [[#image("y.png")]] }, 1, "After raw fence")
scan({ [[```typst]], [[#image("x.png")]] }, 0, "Raw block excluded")
scan({ [[/* outer /* nested */]], [[#image("x.png")]], [[*/ #image("y.png")]] }, 1, "Nested block comments")
scan({ [[// #image("x.png")]] }, 0, "Line comments")
scan({ [[\#image("x.png")]] }, 0, "Escaped hash")
scan({ [[#some-image("x.png")]] }, 0, "Identifier boundary")
scan({ [[#image("x.png"]] }, 0, "Incomplete call")
scan({ [[#image(variable)]] }, 0, "Variables not guessed")
scan({ [[#image("a" + "b.png")]] }, 0, "Dynamic path not guessed")
scan({ [[#image("a\q.png")]] }, 0, "Invalid string escapes")
local parsed = T.scan({ [[#image("quote \" unicode \u{56fe}%20.png")]] })
check(parsed[1].src == 'quote " unicode 图%20.png', "Typst escaping without URL decoding")
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, tmp .. "/main.typ")
vim.bo.filetype = "typst"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "= Image fixture" })
local done, err, paths
I.files(
  { vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png" },
  { filename = 'quote " percent% 图.png', alt = 'A "quoted" image' },
  function(e, p)
    done, err, paths = true, e, p
  end
)
check(
  vim.wait(2000, function()
    return done
  end),
  "Typst import completed"
)
check(not err, err)
check(D.at_line(buf, 2, { max_scan_lines = 100 }) == paths[1], "Inserted image path round trip")
check(
  not D.at_cursor(buf, 2, #vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] + 2, { max_scan_lines = 100 }),
  "Cursor outside reference"
)
check(not I.supported("typst", "x.avif"), "Unsupported compiler formats rejected")
local main = tmp .. "/main.typ"
vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), main)
if vim.fn.executable("typst") == 1 then
  local result = vim.system({ "typst", "compile", main, tmp .. "/main.pdf" }):wait()
  check(result.code == 0, "Actual Typst compilation: " .. (result.stderr or ""))
  if vim.fn.executable("pdfimages") == 1 then
    local embedded = vim.system({ "pdfimages", "-list", tmp .. "/main.pdf" }):wait()
    check(embedded.code == 0 and embedded.stdout:match("image%s+160%s+100"), "Typst PDF embeds image dimensions")
  end
else
  print("typst: real compilation skipped (typst unavailable)")
end
vim.fn.mkdir(tmp .. "/chapter", "p")
vim.api.nvim_buf_set_name(buf, tmp .. "/chapter/section.typ")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { [[#image("/Figures/logo.png")]], [[#image("relative.png")]] })
check(
  D.at_line(buf, 1, { max_scan_lines = 100, root = tmp }) == tmp .. "/Figures/logo.png",
  "Leading slash uses project root"
)
check(
  D.at_line(buf, 2, { max_scan_lines = 100, root = tmp }) == tmp .. "/chapter/relative.png",
  "Relative path uses containing document"
)
done, err = nil, nil
I.files({ vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png" }, { mode = "reference" }, function(e)
  done, err = true, e
end)
check(vim.wait(2000, function()
  return done
end) and err:match("outside the project root"), "Outside reference fails before inserting invalid code")
-- Exercise the real SVG conversion delegate, not a fixture masquerading as PNG.
local svg = tmp .. "/vector.svg"
vim.fn.writefile({
  [[<svg xmlns="http://www.w3.org/2000/svg" width="160" height="100"><rect width="160" height="100" fill="red"/></svg>]],
}, svg)
local completed, prepare_err, image
require("image_tools.media").prepare(svg, {
  transport = "auto",
  magick = "magick",
  cache = tmp .. "/cache",
  max_bytes = 32 * 1024 * 1024,
  max_dimension = 16384,
  max_pixels = 64 * 1024 * 1024,
  convert_timeout = 10000,
}, function(e, p)
  completed, prepare_err, image = true, e, p
end)
check(
  vim.wait(12000, function()
    return completed
  end),
  "SVG conversion completed"
)
check(
  not prepare_err and image.width <= 1920 and image.height <= 1080 and math.abs(image.width / image.height - 1.6) < 0.01,
  prepare_err
)
check(image.source == svg, "SVG conversion source identity")
if vim.fn.executable("typst") == 1 then
  vim.api.nvim_buf_set_name(buf, tmp .. "/images.typ")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "= Vector and PDF" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  done, err, paths = nil, nil, nil
  I.files({ svg, tmp .. "/main.pdf" }, {}, function(e, p)
    done, err, paths = true, e, p
  end)
  check(vim.wait(2000, function()
    return done
  end) and not err, err or "Vector/PDF imports timed out")
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), tmp .. "/images.typ")
  local compiled = vim.system({ "typst", "compile", tmp .. "/images.typ", tmp .. "/images.pdf" }):wait()
  check(compiled.code == 0, "Actual SVG/PDF insertion compilation: " .. (compiled.stderr or ""))
  check(D.at_line(buf, 2, { max_scan_lines = 100 }) == paths[1], "SVG inserted reference")
  check(D.at_line(buf, 3, { max_scan_lines = 100 }) == paths[2], "PDF inserted reference")
end
completed, prepare_err, image = nil, nil, nil
require("image_tools.media").prepare(svg, {
  transport = "auto",
  magick = "magick",
  rsvg = tmp .. "/missing-rsvg",
  cache = tmp .. "/cache",
  max_bytes = 32 * 1024 * 1024,
  max_dimension = 16384,
  max_pixels = 64 * 1024 * 1024,
  convert_timeout = 10000,
}, function(e, p)
  completed, prepare_err, image = true, e, p
end)
check(vim.wait(12000, function()
  return completed
end) and not prepare_err, prepare_err or "MSVG fallback timeout")
check(image.width == 160 and image.height == 100, "Real ImageMagick MSVG fallback")
print("typst: " .. count .. " assertions passed (including real compilation/SVG preview when available)")
