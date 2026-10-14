vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))

local I, D, T =
  require("image_tools.workflow.insert"), require("image_tools.document"), require("image_tools.document.tex")
local tmp = vim.env.IMAGE_TOOLS_TEST_TMP .. "/tex"
vim.fn.mkdir(tmp .. "/plots", "p")
tmp = assert(vim.uv.fs_realpath(tmp))

local source = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
vim.uv.fs_copyfile(source, tmp .. "/plots/figure.png")
vim.uv.fs_copyfile(source, tmp .. "/percent%20.png")

local count = 0
local function check(value, msg)
  count = count + 1
  assert(value, msg)
end

local function document(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/" .. count .. ".tex")
  vim.bo.filetype = "tex"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local buf = document({ [[\graphicspath{{plots/}}]], [[prefix \includegraphics*[width=0.8\linewidth]{figure} suffix]] })
local opts = { max_scan_lines = 100 }

check(D.at_line(buf, 2, opts) == tmp .. "/plots/figure.png", "graphicspath and extension lookup")
check(not D.at_cursor(buf, 2, 0, opts), "Cursor range")
check(D.at_cursor(buf, 2, 15, opts) == tmp .. "/plots/figure.png", "Cursor on command")
check(#T.parse([[\includegraphics{a.png} \includegraphics{b.pdf}]]) == 2, "Multiple commands")
check(#T.parse([[\includegraphicsfoo{a.png}]]) == 0, "Command boundary")
check(#T.parse([[\\includegraphics{a.png}]]) == 0, "Escaped command")
check(#T.parse([[\verb|\includegraphics{a.png}| % \includegraphics{b.png}]]) == 0, "Verb and comments")
check(#T.parse([[\includegraphics{\macro.png}]]) == 0, "Macros not guessed")
check(#T.parse([[\includegraphics[width=1cm]{broken]]) == 0, "Incomplete syntax")
buf = document({ [[% \includegraphics{plots/figure.png}]], [[\includegraphics{percent\%20.png}]] })
check(not D.at_line(buf, 1, opts), "Comments excluded")
check(D.at_line(buf, 2, opts) == tmp .. "/percent%20.png", "TeX literal percent is not URL-decoded")
for _, environment in ipairs({ "verbatim", "lstlisting", "minted", "comment" }) do
  buf = document({
    "\\begin{" .. environment .. "}",
    [[\includegraphics{plots/figure.png}]],
    "\\end{" .. environment .. "}",
    [[\includegraphics{plots/figure.png}]],
  })
  check(not D.at_line(buf, 2, opts), "Excluded environment " .. environment)
  check(D.at_line(buf, 4, opts) == tmp .. "/plots/figure.png", "After environment " .. environment)
end
buf = document({ [[\documentclass{article}]], [[\usepackage{graphicx}]], [[\begin{document}]], [[\end{document}]] })
vim.api.nvim_win_set_cursor(0, { 3, 0 })
local done, err, paths
I.files({ source }, { filename = "space #_&%.png" }, function(e, p)
  done, err, paths = true, e, p
end)
check(
  vim.wait(2000, function()
    return done
  end),
  "LaTeX import completed"
)
check(not err, err)
check(paths[1]:find("space ____.png", 1, true), "Unsafe import characters sanitized")
check(D.at_line(buf, 4, opts) == paths[1], "Inserted detokenize path round trip")
check(not pcall(I.markup, "percent%.png", "", "tex"), "Unsafe reference rejected")
check(not I.supported("tex", "foo.avif"), "Unsupported compiler formats rejected")
local main = tmp .. "/main.tex"
vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), main)
if vim.fn.executable("pdflatex") == 1 then
  local result = vim
    .system({ "pdflatex", "-halt-on-error", "-interaction=nonstopmode", "-output-directory", tmp, main }, { cwd = tmp })
    :wait()
  check(result.code == 0, "Actual pdflatex compilation: " .. (result.stdout or ""):sub(-2000))
  check(vim.uv.fs_stat(tmp .. "/main.pdf") ~= nil, "Compiled PDF exists")
  if vim.fn.executable("pdfimages") == 1 then
    local embedded = vim.system({ "pdfimages", "-list", tmp .. "/main.pdf" }):wait()
    check(
      embedded.code == 0 and embedded.stdout:match("image%s+160%s+100"),
      "Compiled PDF embeds actual image dimensions"
    )
  end
  local completed, prepare_err, image
  require("image_tools.media").prepare(tmp .. "/main.pdf", {
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
    "PDF preview conversion completed"
  )
  check(not prepare_err and image.width > 0 and image.height > 0, prepare_err)
  check(image.source == tmp .. "/main.pdf", "PDF preview retains source identity")
else
  print("tex: real compilation skipped (pdflatex unavailable)")
end
-- VimTeX project roots are shared by insertion and preview, without loading VimTeX.
vim.fn.mkdir(tmp .. "/chapter", "p")
buf = document({ [[\includegraphics{plots/figure.png}]] })
vim.api.nvim_buf_set_name(buf, tmp .. "/chapter/section.tex")
vim.b[buf].vimtex = { root = tmp }
check(D.at_line(buf, 1, opts) == tmp .. "/plots/figure.png", "VimTeX project root")
check(D.base(vim.api.nvim_buf_get_name(buf), {
  root = function()
    return tmp
  end,
}, buf) == tmp, "Explicit root function")
print("tex: " .. count .. " assertions passed (including real compilation/PDF preview when available)")
