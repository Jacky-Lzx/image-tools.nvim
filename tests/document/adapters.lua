vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local api, D, I = require("image_tools"), require("image_tools.document"), require("image_tools.workflow.insert")
local F = require("image_tools.document.formats")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/adapters"
vim.fn.mkdir(tmp, "p")
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ actual = a, expected = b }))
end
local spec = { image_formats = { "png" }, markup = "[[file:$FILE_PATH]]$CURSOR" }
local unregister = api.register_adapter("org", spec)
spec.image_formats[1] = "avif"
eq(api.status().configured, false)
eq(I.supported("org", "a.png"), true)
eq(I.supported("org", "a.avif"), false)
eq(I.markup("a.png", nil, "org"), "[[file:a.png]]")
local formats = D.adapter("org").image_formats()
formats[1] = "avif"
eq(D.adapter("org").image_formats(), { "png" })
eq(F.document_extensions().org, nil)
eq(pcall(api.register_adapter, "tex", spec), false)
eq(pcall(api.register_adapter, "broken", { image_formats = { "png" }, markup = false }), false)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, tmp .. "/note.org")
vim.bo.filetype = "org"
local done, failure, outputs
I.files({ fixture }, {}, function(err, paths)
  failure, outputs, done = err, paths, true
end)
assert(vim.wait(2000, function()
  return done
end))
assert(not failure, failure)
eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], "[[file:Figures/fixture.png]]")
local _, _, status = D.at_line(buf, 2, { max_scan_lines = 100 })
eq(status, "miss")
-- A markup-only adapter must not report every resource as unused.
local inspected, inspection_error
require("image_tools.workflow.assets").check({ buf = buf }, function(err)
  inspection_error, inspected = err, true
end)
assert(vim.wait(1000, function()
  return inspected
end))
assert(inspection_error:find("enumeration", 1, true))
local first = D.adapter("org")
local remove_new = api.register_adapter("org", {
  image_formats = { "png" },
  markup = function(path)
    return "image(" .. path .. ")"
  end,
  references = function()
    return {}
  end,
})
eq(unregister(), false)
assert(D.adapter("org") ~= first)
eq(F.document_extensions().org, "org")
local scratch = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(scratch)
vim.api.nvim_buf_set_name(scratch, tmp .. "/pending.org")
vim.bo.filetype = "org"
done = false
I.files({ fixture }, { directory = "replaced" }, function(err)
  failure, done = err, true
end)
eq(remove_new(), true)
assert(vim.wait(2000, function()
  return done
end))
assert(failure)
eq(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), { "" })
eq(vim.fn.glob(tmp .. "/replaced/*", false, true), {})
eq(D.supported("org"), false)
eq(api.unregister_adapter("html"), false)
-- Custom reference callbacks are used by actual project discovery.
local remove_project = api.register_adapter("diagram", {
  image_formats = { "png" },
  file_extensions = { "dia" },
  markup = "$FILE_PATH",
  references = function(bufnr, row, opts)
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    if line and line ~= "" then
      return {
        {
          path = D.resolve(line, opts._document_path, { literal = true }),
          reference = {
            start_row = row,
            end_row = row,
            start_col = 0,
            end_col = #line,
          },
        },
      }
    end
    return {}
  end,
})
vim.fn.mkdir(tmp .. "/project/Figures", "p")
assert(vim.uv.fs_copyfile(fixture, tmp .. "/project/Figures/a.png"))
vim.fn.writefile({ "Figures/a.png" }, tmp .. "/project/example.dia")
local report
done = false
require("image_tools.workflow.assets").check(
  { scope = "project", project_root = tmp .. "/project", insert = { root = tmp .. "/project" } },
  function(err, value)
    failure, report, done = err, value, true
  end
)
assert(vim.wait(3000, function()
  return done
end))
assert(not failure, failure)
eq(#report.documents, 1)
eq(#report.unreferenced, 0)
eq(report.project_root, tmp .. "/project")
done = false
require("image_tools.workflow.assets").check(
  { scope = "project", project_root = tmp .. "/project" },
  function(err, value)
    failure, report, done = err, value, true
  end
)
eq(remove_project(), true)
assert(vim.wait(3000, function()
  return done
end))
assert(failure:find("registry changed", 1, true))
eq(report, nil)
print("adapters: registration snapshots, insertion, cleanup, replacement rollback and project discovery passed")
