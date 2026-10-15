-- Module: image_tools.workflow.asset_project
-- Purpose:
--   Inspect literal references across a project and its configured asset directories.
-- Architecture:
--   Discover documents asynchronously, prefer live buffers, enumerate offline text
--   in unnamed scratch buffers, then combine references before reporting unused files.
-- Ownership:
--   Own scratch buffers/read descriptors and child cancellation. Snapshot live buffers
--   and disk revisions; edits, renames, removal or cancellation suppress stale reports.
local M = {}
local uv = vim.uv
local version = require("image_tools.media.file_version")
local extensions = { md = "markdown", markdown = "markdown", tex = "tex", ltx = "tex", typ = "typst" }
local function inside(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.check(opts, callback)
  local buf = opts.buf and opts.buf ~= 0 and opts.buf or vim.api.nvim_get_current_buf()
  local document = vim.api.nvim_buf_get_name(buf)
  local settings = vim.tbl_extend("force", require("image_tools.defaults").assets, opts.assets or {})
  local root = opts.project_root or vim.fs.root(document, { ".git" }) or vim.fs.dirname(document)
  local active, scratch, cancel_child = true, nil, nil
  local snapshots, disk_versions, live, directories = {}, {}, {}, {}
  local report = {
    scope = "project",
    document = document,
    documents = {},
    references = {},
    missing = {},
    unreferenced = {},
    scanned = 0,
    truncated = false,
    warnings = {},
  }
  local function cleanup()
    if cancel_child then
      cancel_child()
      cancel_child = nil
    end
    if scratch and vim.api.nvim_buf_is_valid(scratch) then
      vim.api.nvim_buf_delete(scratch, { force = true })
    end
    scratch = nil
  end
  local function done(err)
    if not active then
      return
    end
    active = false
    cleanup()
    callback(err, not err and report or nil)
  end
  local function snapshot(buffer)
    snapshots[buffer] = {
      name = vim.api.nvim_buf_get_name(buffer),
      tick = vim.api.nvim_buf_get_changedtick(buffer),
      ft = vim.bo[buffer].filetype,
    }
  end
  snapshot(buf)
  local function current()
    if not active then
      return false
    end
    for buffer, saved in pairs(snapshots) do
      if
        not vim.api.nvim_buf_is_valid(buffer)
        or not vim.api.nvim_buf_is_loaded(buffer)
        or vim.api.nvim_buf_get_name(buffer) ~= saved.name
        or vim.api.nvim_buf_get_changedtick(buffer) ~= saved.tick
        or vim.bo[buffer].filetype ~= saved.ft
      then
        done("Document changed or unloaded during project inspection")
        return false
      end
    end
    for path in pairs(disk_versions) do
      local loaded = vim.fn.bufnr(path)
      if loaded >= 0 and vim.api.nvim_buf_is_loaded(loaded) and not snapshots[loaded] then
        done("Document opened during project inspection: " .. path)
        return false
      end
    end
    return true
  end
  local function warning(message)
    report.truncated = true
    report.warnings[#report.warnings + 1] = message
  end
  -- Each traversal has an entry budget; symlinks and excluded directory names are skipped.
  local function walk(roots, visit, completed)
    local waiting, visited, entries = vim.deepcopy(roots), {}, 0
    local excluded = {}
    for _, name in ipairs(settings.exclude_dirs) do
      excluded[name] = true
    end
    local next_directory
    next_directory = function()
      if not current() then
        return
      end
      local directory = table.remove(waiting, 1)
      if not directory then
        completed()
        return
      end
      local directory_stat = uv.fs_lstat(directory)
      if directory_stat and directory_stat.type == "link" then
        vim.schedule(next_directory)
        return
      end
      directory = uv.fs_realpath(directory) or directory
      if visited[directory] then
        vim.schedule(next_directory)
        return
      end
      visited[directory] = true
      uv.fs_scandir(
        directory,
        vim.schedule_wrap(function(err, scan)
          if not current() then
            return
          end
          if err then
            if not tostring(err):match("ENOENT") then
              warning("Cannot inspect directory: " .. directory)
            end
            next_directory()
            return
          end
          local step
          step = function()
            if not current() then
              return
            end
            local name = uv.fs_scandir_next(scan)
            if not name then
              next_directory()
              return
            end
            entries = entries + 1
            if entries > settings.max_entries then
              warning("Traversal stopped at assets.max_entries: " .. directory)
              completed()
              return
            end
            local path = directory .. "/" .. name
            uv.fs_lstat(
              path,
              vim.schedule_wrap(function(stat_err, stat)
                if not current() then
                  return
                end
                if stat_err then
                  warning("Cannot inspect file: " .. path)
                elseif stat.type == "directory" and not excluded[name] then
                  waiting[#waiting + 1] = path
                elseif stat.type == "file" then
                  visit(path, stat)
                end
                vim.schedule(step)
              end)
            )
          end
          step()
        end)
      )
    end
    next_directory()
  end
  local function finish()
    local paths = vim.tbl_keys(disk_versions)
    local index = 1
    local verify
    verify = function()
      if not current() then
        return
      end
      local path = paths[index]
      if not path then
        table.sort(report.unreferenced)
        done()
        return
      end
      index = index + 1
      uv.fs_stat(
        path,
        vim.schedule_wrap(function(err, stat)
          if not current() then
            return
          end
          if err or version.key(path, stat) ~= disk_versions[path] then
            done("Document changed on disk during project inspection: " .. path)
            return
          end
          verify()
        end)
      )
    end
    verify()
  end
  local function inspect_assets()
    walk(vim.tbl_keys(directories), function(path)
      if require("image_tools.media.formats").supported(path) then
        local key = uv.fs_realpath(path) or path
        if not report.references[key] then
          report.unreferenced[#report.unreferenced + 1] = path
        end
      end
    end, finish)
  end
  local documents, index = {}, 1
  local next_document
  local function inspect_buffer(buffer, path, ft)
    local child_opts = vim.tbl_extend(
      "force",
      opts,
      { scope = "document", buf = buffer, _references_only = true, _document_path = path, _document_filetype = ft }
    )
    cancel_child = require("image_tools.workflow.assets").check(child_opts, function(err, result)
      cancel_child = nil
      if not current() then
        return
      end
      if err then
        done(err)
        return
      end
      directories[result.directory] = true
      report.documents[#report.documents + 1] = path
      report.scanned = report.scanned + result.scanned
      if result.truncated then
        warning("Document stopped at max_scan_lines: " .. path)
      end
      vim.list_extend(report.missing, result.missing)
      for image, locations in pairs(result.references) do
        report.references[image] = report.references[image] or {}
        vim.list_extend(report.references[image], locations)
      end
      cleanup()
      vim.schedule(next_document)
    end)
  end
  next_document = function()
    if not current() then
      return
    end
    local path = documents[index]
    index = index + 1
    if not path then
      inspect_assets()
      return
    end
    if live[path] then
      inspect_buffer(live[path], path, vim.bo[live[path]].filetype)
      return
    end
    uv.fs_open(path, "r", 384, function(open_err, fd)
      if not fd then
        vim.schedule(function()
          if current() then
            done(open_err)
          end
        end)
        return
      end
      if not active then
        uv.fs_close(fd)
        return
      end
      uv.fs_fstat(fd, function(stat_err, stat)
        if not active or stat_err or stat.type ~= "file" or stat.size > settings.max_document_bytes then
          uv.fs_close(fd)
          vim.schedule(function()
            if not current() then
              return
            end
            warning("Document unreadable or exceeds assets.max_document_bytes: " .. path)
            next_document()
          end)
          return
        end
        uv.fs_read(fd, stat.size, 0, function(read_err, data)
          uv.fs_close(fd)
          vim.schedule(function()
            if not current() then
              return
            end
            if read_err or not data or #data ~= stat.size then
              done(read_err or "Document changed while reading: " .. path)
              return
            end
            disk_versions[path] = version.key(path, stat)
            if data:find("%z") then
              warning("Binary document skipped: " .. path)
              next_document()
              return
            end
            local lines = vim.split(data:gsub("\r\n", "\n"), "\n", { plain = true })
            if #lines > 1 and lines[#lines] == "" then
              table.remove(lines)
            end
            scratch = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
            inspect_buffer(scratch, path, extensions[path:match("%.([^./]+)$"):lower()])
          end)
        end)
      end)
    end)
  end
  vim.schedule(function()
    if not current() then
      return
    end
    if (document == "" and not opts.project_root) or not root then
      done("Save a document or provide project_root before project inspection")
      return
    end
    if type(root) ~= "string" or root == "" then
      done("project_root must be a directory path")
      return
    end
    root = uv.fs_realpath(vim.fn.fnamemodify(root, ":p"))
    local stat = root and uv.fs_stat(root)
    if not stat or stat.type ~= "directory" then
      done("Project root is not a directory")
      return
    end
    report.project_root = root
    local found = {}
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buffer) then
        local name = vim.api.nvim_buf_get_name(buffer)
        local path = uv.fs_realpath(name) or name
        local excluded = false
        if inside(path, root) then
          for component in path:sub(#root + 2):gmatch("([^/]+)/") do
            if vim.tbl_contains(settings.exclude_dirs, component) then
              excluded = true
              break
            end
          end
        end
        if
          not excluded
          and inside(path, root)
          and require("image_tools.document.formats").supported(vim.bo[buffer].filetype)
        then
          live[path], found[path] = buffer, true
          snapshot(buffer)
        end
      end
    end
    walk({ root }, function(path)
      local extension = path:match("%.([^./]+)$")
      if extension and extensions[extension:lower()] then
        found[path] = true
      end
    end, function()
      documents = vim.tbl_keys(found)
      table.sort(documents)
      next_document()
    end)
  end)
  return function()
    active = false
    cleanup()
  end
end
return M
