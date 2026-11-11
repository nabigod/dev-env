-- Neovim 0.5 provides vim.opt and vim.fn.has() for this guarded setup.
if vim.fn.has("nvim-0.5") == 1 then
  vim.opt.guicursor = "n:blinkon0,i:block,c:Cursor/lCursor"
end

-- A later plugin layer can provide this module without changing the core entry point.
local ok, plugin_layer = pcall(require, "portable_devenv.plugins")
if ok and type(plugin_layer.setup) == "function" then
  plugin_layer.setup()
end
