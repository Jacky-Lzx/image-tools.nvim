vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local count = 0
local function eq(actual, expected, message)
  count = count + 1
  assert(vim.deep_equal(actual, expected), message .. "\n" .. vim.inspect(actual) .. "\n" .. vim.inspect(expected))
end
local Runtime, config = require("image_tools.runtime"), require("image_tools.config")
local supplied = { buffer = { formats = { "png" } }, insert = { directory = "assets" } }
local normalized = config.resolve(supplied)
normalized.buffer.formats[1], normalized.insert.directory = "pdf", "changed"
eq(supplied.buffer.formats[1], "png", "Normalized lists do not mutate caller options")
eq(supplied.insert.directory, "assets", "Normalized nested options do not mutate caller options")
eq(config.resolve().insert.directory, "Figures", "Default options stay independent")
local previews, buffers, renderers = {}, {}, {}
local dependencies = {
  preview = {
    new = function(options)
      local instance = { options = options, opens = 0, closes = 0, destroys = 0 }
      instance.transfer = {
        status = function()
          return {}
        end,
      }
      function instance:open(path)
        self.path, self.opens = path, self.opens + 1
        return true
      end
      function instance:close()
        self.closes, self.state = self.closes + 1, nil
      end
      function instance:destroy()
        self.destroys = self.destroys + 1
        self:close()
      end
      previews[#previews + 1] = instance
      return instance
    end,
  },
  buffer = {
    new = function(options)
      local instance = { options = options, setups = 0, clears = 0, destroys = 0 }
      function instance:setup()
        self.setups = self.setups + 1
      end
      function instance:clear_cache()
        self.clears = self.clears + 1
      end
      function instance:destroy()
        self.destroys = self.destroys + 1
      end
      function instance:status()
        return nil
      end
      buffers[#buffers + 1] = instance
      return instance
    end,
  },
  picker = {
    preview = function(ctx)
      local renderer = { destroys = 0 }
      function renderer:destroy()
        self.destroys = self.destroys + 1
      end
      ctx.picker._image_tools_preview = renderer
      renderers[#renderers + 1] = renderer
    end,
  },
  document = {
    supported = function()
      return true
    end,
    at_line = function(_, _, options)
      return options.root .. "/fixture.png"
    end,
  },
}
local a = Runtime.new(config.resolve({ root = "/private/tmp/first" }), dependencies)
local b = Runtime.new(config.resolve({ root = "/private/tmp/second" }), dependencies)
eq(vim.fn.exists("#image_tools"), 0, "Constructing runtimes installs no handlers")
eq(vim.fn.exists(":ImagePreview"), 0, "Constructing runtimes installs no commands")
eq({ buffers[1].setups, buffers[2].setups }, { 0, 0 }, "Buffer setup waits for start")
a:hover({ silent = true })
b:hover({ silent = true })
eq(
  { previews[1].path, previews[2].path },
  { "/private/tmp/first/fixture.png", "/private/tmp/second/fixture.png" },
  "Each runtime uses its own configuration and preview"
)
a:snacks_preview({ picker = {} })
b:snacks_preview({ picker = {} })
a.options.auto_preview = false
eq(b.options.auto_preview, true, "Config mutation is isolated")
a.options.auto_preview = true
local registered = {}
local create = vim.api.nvim_create_user_command
vim.api.nvim_create_user_command = function(name, callback, opts)
  registered[name] = callback
  return create(name, callback, opts)
end
a:start()
local handler_count = #vim.api.nvim_get_autocmds({ group = "image_tools" })
local old_command = registered.ImagePreview
local old_callback = vim.api.nvim_get_autocmds({ group = "image_tools", event = "CursorMoved" })[1].callback
a:schedule_refresh()
a:destroy()
eq({ renderers[1].destroys, renderers[2].destroys }, { 1, 0 }, "Destroy releases only owned picker renderers")
eq(vim.fn.exists("#image_tools"), 0, "Destroy removes runtime autocmds")
eq(vim.fn.exists(":ImagePreview"), 0, "Destroy removes runtime commands")
eq({ previews[1].destroys, buffers[1].destroys }, { 1, 1 }, "Destroy releases owned preview and buffers")
eq({ previews[2].destroys, buffers[2].destroys }, { 0, 0 }, "Destroy does not release another runtime's controllers")
a:destroy()
eq({ previews[1].destroys, buffers[1].destroys }, { 1, 1 }, "Destroy is idempotent")
b:start()
local opens_a, opens_b = previews[1].opens, previews[2].opens
old_callback({})
old_command({ args = "/private/tmp/old.png" })
eq({ previews[1].opens, previews[2].opens }, { opens_a, opens_b }, "Old autocmd and command callbacks are inert")
vim.wait(30, function()
  return false
end)
eq(previews[1].opens, opens_a, "Queued refresh cannot revive destroyed runtime")
eq(previews[2].opens, opens_b + 1, "Only new runtime's refresh executes")
eq(#vim.api.nvim_get_autocmds({ group = "image_tools" }), handler_count, "Replacement keeps one set of handlers")
vim.cmd("ImagePreview /private/tmp/new.png")
eq(previews[2].path, "/private/tmp/new.png", "New command targets current runtime")
opens_b = previews[2].opens
b:schedule_refresh()
b:schedule_refresh()
vim.wait(30, function()
  return false
end)
eq(previews[2].opens, opens_b + 1, "Refresh requests are coalesced")
vim.api.nvim_del_user_command("ImagePage")
b:destroy()
eq(renderers[2].destroys, 1, "Replacement releases its own picker renderer")
eq(vim.fn.exists("#image_tools"), 0, "Destroy tolerates externally removed command")
vim.api.nvim_create_user_command = create

-- Public setup validates before replacement; failed constructors also preserve it.
package.loaded["image_tools.preview"] = dependencies.preview
package.loaded["image_tools.buffer"] = dependencies.buffer
local api = require("image_tools")
api.setup({ auto_preview = false, transport = "direct" })
api.preview("/private/tmp/current.png")
local current_preview, current_buffer = previews[#previews], buffers[#buffers]
local current_handlers = #vim.api.nvim_get_autocmds({ group = "image_tools" })
eq(pcall(api.setup, { position = "invalid" }), false, "Invalid config is rejected")
eq(api.status().transport, "direct", "Invalid setup retains old configuration")
eq({ current_preview.destroys, current_buffer.destroys }, { 0, 0 }, "Invalid setup does not destroy current resources")
eq(#vim.api.nvim_get_autocmds({ group = "image_tools" }), current_handlers, "Invalid setup retains handlers")
api.preview("/private/tmp/still-active.png")
eq(current_preview.path, "/private/tmp/still-active.png", "Old API stays usable after invalid setup")
package.loaded["image_tools.preview"] = {
  new = function()
    error("constructor failed")
  end,
}
eq(pcall(api.setup, {}), false, "Constructor failure is propagated")
eq({ current_preview.destroys, current_buffer.destroys }, { 0, 0 }, "Constructor failure retains old instance")
package.loaded["image_tools.preview"] = dependencies.preview
api.setup({ auto_preview = false })
eq({ current_preview.destroys, current_buffer.destroys }, { 1, 1 }, "Valid setup replaces resources exactly once")
eq(api.status().transport, "auto", "Replacement uses new normalized config")
eq(
  #vim.api.nvim_get_autocmds({ group = "image_tools" }),
  current_handlers,
  "Repeated public setup keeps one set of handlers"
)
-- A partially started replacement must not leave commands/groups behind.
local real_register = require("image_tools.commands").register
require("image_tools.commands").register = function(runtime)
  real_register(runtime)
  error("registration failed")
end
eq(pcall(api.setup, {}), false, "Startup failure is propagated")
eq(api.status().configured, false, "Startup failure leaves facade unconfigured")
eq(vim.fn.exists("#image_tools"), 0, "Startup failure removes its autocmd group")
eq(vim.fn.exists(":ImagePreview"), 0, "Startup failure removes registered commands")
require("image_tools.commands").register = real_register
api.setup({ auto_preview = false })
eq(api.status().configured, true, "Setup recovers after startup failure")
local waiting, callbacks = true, {}
local async_dependencies = vim.tbl_extend("force", dependencies, {
  document = {
    at_line = function(_, _, options)
      if waiting then
        callbacks[#callbacks + 1] = options._treesitter_ready
        return nil, "pending", "pending"
      end
      return "/private/tmp/ready.png"
    end,
  },
})
local async = Runtime.new(config.resolve({ auto_preview = false }), async_dependencies)
async:hover({ silent = true })
async:hover({ silent = true })
eq(#callbacks, 1, "Repeated movement coalesces pending reference subscriptions")
waiting = false
callbacks[1]()
eq(async.preview.opens, 1, "Manual hover resumes with automatic preview disabled")
waiting = true
async:hover({ silent = true })
async:close()
waiting = false
callbacks[2]()
eq(async.preview.opens, 1, "Closing cancels delayed preview")
waiting = true
async:hover({ silent = true })
async:clear_cache()
waiting = false
callbacks[3]()
eq(async.preview.opens, 1, "Cache clear cancels a pending syntax preview")
waiting = true
async:hover({ silent = true })
async:destroy()
waiting = false
callbacks[4]()
eq(async.preview.opens, 1, "Destroyed runtime cannot reopen delayed preview")
print("image-tools runtime: " .. count .. " assertions passed")
