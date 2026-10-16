vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local media, prepare, config =
  require("image_tools.media"), require("image_tools.media.prepare"), require("image_tools.config")
local renderer = require("image_tools.media.math")
local queue = require("image_tools.media.conversion_queue")
local tmp = assert(vim.env.IMAGE_TOOLS_TEST_TMP) .. "/math"
vim.fn.mkdir(tmp, "p")
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function wait(predicate, message)
  check(vim.wait(15000, predicate, 5), message)
end
local opts = config.resolve({ cache = tmp .. "/cache", math = { foreground = "#cad3f5" }, transport = "direct" })
opts._formula = [=[\[\frac{a}{b} + \sum_{i=1}^n i^2\]]=]
local key = renderer.key(opts)
for _, override in ipairs({
  { density = 200 },
  { preamble = "" },
  { foreground = "#ffffff" },
  { latex = "other-latex" },
  { dvipng = "other-dvipng" },
}) do
  check(
    renderer.key(vim.tbl_deep_extend("force", opts, { math = override })) ~= key,
    "Renderer settings change cache key"
  )
end
local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
local auto = vim.tbl_deep_extend("force", opts, { math = { foreground = "auto" } })
vim.api.nvim_set_hl(0, "Normal", { fg = "#112233" })
local dark = renderer.key(auto)
vim.api.nvim_set_hl(0, "Normal", { fg = "#445566" })
check(renderer.key(auto) ~= dark, "Theme color changes cache key")
vim.api.nvim_set_hl(0, "Normal", normal)
local called, error_message = false, nil
local unavailable = vim.tbl_deep_extend("force", opts, { math = { latex = "/missing-image-tools-latex" } })
local close = media.prepare("image-tools-math:missing", unavailable, function(err)
  called, error_message = true, err
end)
wait(function()
  return called
end, "Missing tool returns asynchronously")
check(error_message:find("requires /missing-image-tools-latex", 1, true), "Missing dependency is actionable")
close()
-- Deterministic worker tests use real PNG validation with controlled process exits.
local real_run, runs, jobs, workspaces = queue.run, 0, {}, {}
queue.run = function(command, options, callback)
  runs = runs + 1
  workspaces[#workspaces + 1] = options.cwd
  local job = { command = command, options = options, callback = callback }
  jobs[#jobs + 1] = job
  return function()
    job.cancelled = true
  end
end
local a, b, cancelled_delivery
local first = prepare.request("image-tools-math:shared", opts, function(_, image)
  a = image
end)
local second = prepare.request("image-tools-math:shared", opts, function(_, image)
  b = image
end)
wait(function()
  return #jobs == 1
end, "Equivalent formulas coalesce")
check(prepare.status().pending_jobs == 1, "Shared worker is visible")
check(vim.tbl_contains(jobs[1].command, "-no-shell-escape"), "TeX disables shell escape")
check(
  jobs[1].options.env.openin_any == "p" and jobs[1].options.env.openout_any == "p",
  "TeX file access uses restricted policy"
)
local source = table.concat(vim.fn.readfile(jobs[1].options.cwd .. "/formula.tex"), "\n")
check(source:find(opts._formula, 1, true), "Multiline formula is written without NUL substitution")
first.cancel()
check(not jobs[1].cancelled, "One subscriber can cancel without stopping another")
local stamp = vim.uv.hrtime()
jobs[1].callback({ code = 0, timing = { queued = stamp, started = stamp, finished = stamp } })
check(#jobs == 2 and vim.tbl_contains(jobs[2].command, "--nogs"), "Rasterizer disables PostScript delegates")
local output = jobs[2].command[#jobs[2].command - 1]
assert(vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", output))
jobs[2].callback({ code = 0, timing = { queued = stamp, started = stamp, finished = stamp } })
wait(function()
  return b ~= nil
end, "Validated PNG delivered to remaining subscriber")
check(not a and b.source == "image-tools-math:shared", "Cancelled subscriber receives no result")
check(not vim.uv.fs_stat(workspaces[1]), "Successful job removes workspace")
local report
require("image_tools.media.disk_cache").inspect(opts, function(result)
  report = result
end)
wait(function()
  return report ~= nil
end, "Inspect formula lease")
check(report.protected == 1, "Delivered formula remains pinned")
local cached
local cached_close = media.prepare("image-tools-math:shared", opts, function(err, image)
  check(not err, "Cache read succeeds")
  cached = image
end)
wait(function()
  return cached ~= nil
end, "Cached formula read")
check(runs == 2 and cached.path == b.path, "Cache avoids both processes")
check(vim.deep_equal(cached.display_size, b.display_size), "Cache reads restore logical formula dimensions")
cached_close()
second.close()
local changed = vim.tbl_extend("force", opts, { _formula = "$c$" })
local third = prepare.request("image-tools-math:cancel", changed, function()
  cancelled_delivery = true
end)
wait(function()
  return #jobs == 3
end, "Cancellable job starts")
third.close()
check(jobs[3].cancelled and not vim.uv.fs_stat(workspaces[3]), "Last cancellation stops work and removes workspace")
jobs[3].callback({ code = 1, stderr = "cancelled", timing = { queued = stamp, started = stamp, finished = stamp } })
check(not cancelled_delivery and prepare.status().pending_jobs == 0, "Late process exit cannot deliver")
queue.run = real_run
-- Exercise the actual installed TeX toolchain when available.
if vim.fn.executable(opts.math.latex) == 1 and vim.fn.executable(opts.math.dvipng) == 1 then
  local samples = {}
  for _, density in ipairs({ 180, 360 }) do
    local done, failure = false, nil
    local settings = vim.tbl_deep_extend("force", opts, {
      _formula = [=[\[\frac{a}{b} + \sqrt{x}\]]=],
      math = { density = density },
    })
    local cleanup = media.prepare("image-tools-math:resolution", settings, function(err, image)
      done, failure, samples[density] = true, err, image
    end)
    wait(function()
      return done
    end, "Resolution comparison render completes")
    check(not failure and samples[density], tostring(failure))
    cleanup()
  end
  local low, high = samples[180], samples[360]
  check(
    high.width > low.width * 1.8 and high.height > low.height * 1.8,
    "360 DPI increases actual raster detail on both axes"
  )
  check(
    math.abs(high.display_size.width - low.display_size.width) <= 1
      and math.abs(high.display_size.height - low.display_size.height) <= 1,
    "Higher DPI preserves logical display dimensions within raster rounding"
  )
  check(high.path ~= low.path, "Higher DPI does not reuse the low-resolution disk output")
  for _, expression in ipairs({
    "$x^2$",
    [=[\[\frac{1}{2} + \sqrt{x}\]]=],
    "\\begin{align*}\na &= b + c \\\\\nd &= e^2\n\\end{align*}",
    "$\\vect{x}$",
  }) do
    local done, actual, err = false, nil, nil
    local settings = vim.tbl_extend("force", opts, { _formula = expression })
    if expression:find("\\vect", 1, true) then
      settings = vim.tbl_deep_extend("force", settings, {
        math = { preamble = opts.math.preamble .. "\n\\newcommand{\\vect}[1]{\\mathbf{#1}}" },
      })
    end
    local cleanup = media.prepare(
      "image-tools-math:real:" .. vim.fn.sha256(expression),
      settings,
      function(message, image)
        done, err, actual = true, message, image
      end
    )
    wait(function()
      return done
    end, "Real TeX render completes")
    check(not err and actual and actual.width > 1 and actual.height > 1, tostring(err))
    check(not actual.data and actual.path:match("%.png$"), "Metadata-only formula delivery")
    local identify = vim.system({ "magick", "identify", "-format", "%[opaque]", actual.path }, { text = true }):wait()
    check(identify.code == 0 and identify.stdout == "False", "Formula PNG has transparent pixels")
    cleanup()
  end
  local done, failure = false, nil
  local cleanup = media.prepare(
    "image-tools-math:invalid",
    vim.tbl_extend("force", opts, { _formula = "$\\notARealCommand$" }),
    function(err)
      done, failure = true, err
    end
  )
  wait(function()
    return done
  end, "Invalid TeX completes")
  check(failure and failure:find("Formula rendering failed", 1, true), "TeX errors are reported")
  cleanup()
else
  print("[skip] Real formula compilation: latex/dvipng unavailable")
end
print("media math: " .. checks .. " assertions passed")
