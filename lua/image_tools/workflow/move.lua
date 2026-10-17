-- Project image refactoring: prepare a reviewable plan, validate every snapshot,
-- then publish the destination and update documents with rollback on failure.
local M = {}
local uv = vim.uv
local version = require("image_tools.media.file_version")

local function absolute(path)
  assert(type(path) == "string" and path ~= "" and not path:find("[%z\r\n]"), "Invalid image path")
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function key(path)
  local stat = uv.fs_stat(path)
  return stat and version.key(path, stat)
end

local function read(path)
  local fd = assert(uv.fs_open(path, "r", 384))
  local stat = assert(uv.fs_fstat(fd))
  local data, err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return assert(data, err)
end

local function stage(path, data, mode)
  local fd, err = uv.fs_open(path, "wx", mode)
  assert(fd, err)
  local ok, failure = pcall(function()
    local offset = 0
    while offset < #data do
      local written = assert(uv.fs_write(fd, data:sub(offset + 1), offset))
      assert(written > 0, "Short document write")
      offset = offset + written
    end
    assert(uv.fs_fsync(fd))
  end)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(path)
    error(failure)
  end
end

-- Disk documents are atomically replaced; live buffers retain unsaved edits and
-- are left modified. Applying twice, or after an intervening edit, is rejected.
function M.apply(plan)
  if plan.applied or plan.cancelled then
    return false, "Move plan is no longer active"
  end
  local staged, published, touched = {}, false, {}
  local ok, err = pcall(function()
    assert(require("image_tools.document.formats").generation() == plan.generation, "Document adapters changed")
    assert(key(plan.source) == plan.source_version, "Image source changed since preview")
    assert(not uv.fs_lstat(plan.target), "Destination already exists")
    for path, saved in pairs(plan.snapshots) do
      if saved.buf then
        assert(
          vim.api.nvim_buf_is_loaded(saved.buf)
            and (uv.fs_realpath(vim.api.nvim_buf_get_name(saved.buf)) or vim.api.nvim_buf_get_name(saved.buf)) == path
            and vim.api.nvim_buf_get_changedtick(saved.buf) == saved.tick
            and vim.bo[saved.buf].filetype == saved.filetype,
          "Document changed since preview: " .. path
        )
      else
        local loaded = vim.fn.bufnr(path)
        assert(not (loaded >= 0 and vim.api.nvim_buf_is_loaded(loaded)), "Document opened since preview: " .. path)
        assert(key(path) == saved.version, "Document changed on disk since preview: " .. path)
      end
    end
    for _, change in ipairs(plan.changes) do
      local saved = plan.snapshots[change.path]
      if saved.buf then
        assert(
          vim.bo[saved.buf].modifiable and not vim.bo[saved.buf].readonly,
          "Document is not writable: " .. change.path
        )
      else
        assert(uv.fs_lstat(change.path).type == "file", "Refusing to replace a document symlink")
        local stem = change.path .. ".image-tools-" .. uv.os_getpid() .. "-" .. uv.hrtime()
        local item = { path = change.path, temp = stem .. ".tmp", backup = stem .. ".bak" }
        staged[#staged + 1] = item
        assert(uv.fs_copyfile(change.path, item.backup, 1))
        stage(item.temp, change.data, uv.fs_stat(change.path).mode)
      end
    end
    vim.fn.mkdir(vim.fs.dirname(plan.target), "p")
    assert(uv.fs_copyfile(plan.source, plan.target, 1)) -- exclusive, also works across filesystems
    published = true
    assert(key(plan.source) == plan.source_version, "Image source changed during copy")
    for _, item in ipairs(staged) do
      assert(key(item.path) == plan.snapshots[item.path].version, "Document changed during apply: " .. item.path)
      assert(uv.fs_rename(item.temp, item.path))
      item.committed = true
    end
    for _, change in ipairs(plan.changes) do
      local saved = plan.snapshots[change.path]
      if saved.buf then
        touched[#touched + 1] = saved
        saved.modified = vim.bo[saved.buf].modified
        vim.api.nvim_buf_call(saved.buf, function()
          vim.cmd("let &g:undolevels = &g:undolevels")
        end)
        vim.api.nvim_buf_set_lines(saved.buf, 0, -1, false, change.lines)
      end
    end
    assert(uv.fs_unlink(plan.source))
    plan.applied = true
  end)
  local recovery = {}
  if not ok then
    for i = #touched, 1, -1 do
      local saved = touched[i]
      local restored, failure = pcall(vim.api.nvim_buf_set_lines, saved.buf, 0, -1, false, saved.lines)
      if restored then
        vim.bo[saved.buf].modified = saved.modified
      else
        recovery[#recovery + 1] = tostring(failure)
      end
    end
    for _, item in ipairs(staged) do
      if item.committed then
        local restored, failure = uv.fs_rename(item.backup, item.path)
        if not restored then
          recovery[#recovery + 1] = tostring(failure) .. "; backup: " .. item.backup
        end
        item.keep_backup = not restored
      end
    end
    if published then
      local removed, failure = uv.fs_unlink(plan.target)
      if not removed then
        recovery[#recovery + 1] = tostring(failure)
      end
    end
  end
  for _, item in ipairs(staged) do
    uv.fs_unlink(item.temp)
    if not item.keep_backup then
      uv.fs_unlink(item.backup)
    end
  end
  if #recovery > 0 then
    err = tostring(err) .. "\nRollback needs attention: " .. table.concat(recovery, "\n")
  end
  return ok, not ok and tostring(err) or nil
end

function M.plan(source, target, opts, callback)
  local options =
    vim.tbl_extend("force", opts, { scope = "project", _capture_documents = true, _references_only = true })
  local active = true
  local ok, plan = pcall(function()
    source, target = absolute(source), absolute(target)
    local stat = assert(uv.fs_lstat(source), "Image source does not exist")
    assert(stat.type == "file", "Image source must be a regular file, not a symlink")
    assert(require("image_tools.media.formats").supported(source), "Unsupported image source format")
    assert(
      source:match("%.([^./]+)$"):lower() == (target:match("%.([^./]+)$") or ""):lower(),
      "Moving must preserve the image extension"
    )
    assert(not uv.fs_lstat(target), "Destination already exists")
    assert(stat.size <= opts.max_bytes, "Image exceeds max_bytes")
    return {
      source = source,
      target = target,
      source_version = version.key(source, stat),
      changes = {},
      generation = require("image_tools.document.formats").generation(),
    }
  end)
  if not ok then
    vim.schedule(function()
      if active then
        active = false
        callback(tostring(plan))
      end
    end)
    return function()
      active = false
    end
  end
  local cancel_scan = require("image_tools.workflow.assets").check(options, function(err, report)
    if not active then
      return
    end
    local scratch
    local built, failure = pcall(function()
      assert(not err, err)
      assert(not report.truncated, "Project scan is incomplete; adjust assets/max_scan_lines before moving images")
      plan.snapshots = report.snapshots
      local locations = report.references[uv.fs_realpath(source) or source] or {}
      local by_document = {}
      for _, location in ipairs(locations) do
        by_document[location.filename] = by_document[location.filename] or {}
        table.insert(by_document[location.filename], location.reference)
      end
      for _, path in ipairs(vim.fn.sort(vim.tbl_keys(by_document))) do
        local saved = plan.snapshots[path]
        local buffer = saved.buf
        if not buffer then
          scratch = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(scratch, 0, -1, false, saved.lines)
          buffer = scratch
        end
        local edits, seen = {}, {}
        for _, ref in ipairs(by_document[path]) do
          local edit = require("image_tools.document.edit").path(buffer, saved.filetype, ref, target, path, opts)
          local id = table.concat({ edit.row, edit.first, edit.last }, ":")
          if not seen[id] then
            edits[#edits + 1], seen[id] = edit, true
          end
        end
        table.sort(edits, function(a, b)
          return a.row > b.row or a.row == b.row and a.first > b.first
        end)
        local lines = vim.deepcopy(saved.lines)
        local previous
        for _, edit in ipairs(edits) do
          assert(
            edit.row >= 1
              and edit.row <= #lines
              and edit.first >= 0
              and edit.last >= edit.first
              and edit.last <= #saved.lines[edit.row]
              and not edit.text:find("[\r\n%z]"),
            "Invalid adapter path edit"
          )
          assert(
            not previous or previous.row ~= edit.row or edit.last <= previous.first,
            "Overlapping image path edits"
          )
          lines[edit.row] = lines[edit.row]:sub(1, edit.first) .. edit.text .. lines[edit.row]:sub(edit.last + 1)
          previous = edit
        end
        local change = { path = path, lines = lines, edits = edits }
        if not saved.buf then
          local original = read(path)
          assert(key(path) == saved.version, "Document changed while preparing move: " .. path)
          local eol = original:find("\r\n", 1, true) and "\r\n" or "\n"
          change.data = table.concat(lines, eol) .. (original:sub(-1) == "\n" and eol or "")
        end
        plan.changes[#plan.changes + 1] = change
        if scratch then
          vim.api.nvim_buf_delete(scratch, { force = true })
          scratch = nil
        end
      end
    end)
    if scratch then
      pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    end
    active = false
    callback(not built and tostring(failure) or nil, built and plan or nil)
  end)
  return function()
    active = false
    cancel_scan()
  end
end

function M.move(source, target, opts, callback)
  callback = callback
    or function(err, plan)
      if err ~= "Cancelled" then
        vim.notify(
          err or string.format("Moved image; updated %d document(s). Save modified buffers with :wall", #plan.changes),
          err and vim.log.levels.ERROR or vim.log.levels.INFO
        )
      end
    end
  local active, preview, plan = true, nil, nil
  local function finish(err)
    if not active then
      return
    end
    active = false
    if preview and vim.api.nvim_buf_is_valid(preview) then
      pcall(vim.api.nvim_buf_delete, preview, { force = true })
    end
    callback(err, not err and plan or nil)
  end
  local cancel_scan = M.plan(source, target, opts, function(err, result)
    if not active then
      return
    end
    if err then
      finish(err)
      return
    end
    plan = result
    local function apply()
      if not active then
        return
      end
      local applied, failure = M.apply(plan)
      finish(not applied and failure or nil)
    end
    if opts.confirm == false then
      apply()
      return
    end
    local lines = {
      "Move: " .. source,
      "To:   " .. target,
      "",
      "Live buffers stay modified; unopened documents are saved.",
      "Only recognized references in the scanned project are updated.",
      "",
    }
    for _, change in ipairs(plan.changes) do
      lines[#lines + 1] = "--- " .. change.path
      local diff = vim.diff(
        table.concat(plan.snapshots[change.path].lines, "\n") .. "\n",
        table.concat(change.lines, "\n") .. "\n",
        { result_type = "unified" }
      )
      vim.list_extend(lines, vim.split(diff, "\n", { plain = true }))
    end
    preview = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(preview, 0, -1, false, lines)
    vim.bo[preview].filetype, vim.bo[preview].modifiable = "diff", false
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, preview)
    vim.ui.select(
      { "Apply move", "Cancel" },
      { prompt = string.format("Move image and update %d document(s)?", #plan.changes) },
      function(choice)
        if choice == "Apply move" then
          apply()
        else
          finish("Cancelled")
        end
      end
    )
  end)
  return function()
    if plan then
      plan.cancelled = true
    end
    cancel_scan()
    finish("Cancelled")
  end
end

return M
