-- Set line numbers
vim.opt.number = true

-- Set indentation
vim.opt.autoindent = true
vim.opt.cindent = true
vim.opt.smartindent = true

-- Set text wrapping
vim.opt.wrap = true

-- Show the cursor position
vim.opt.ruler = true

-- Tab and indent settings
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

-- Set file encoding
vim.opt.fileencodings = { "ucs-bom", "utf-8", "euc-kr", "latin1" }
vim.opt.fileencoding = "utf-8"

-- Enable search highlighting
vim.opt.hlsearch = true

-- Use the system clipboard
vim.opt.clipboard = "unnamedplus"

-- Set cursor shape
vim.opt.guicursor = "n:blinkon0,i:block,c:Cursor/lCursor"

-- Set colorscheme
vim.cmd("colorscheme jellybeans")

-- Enable file type detection and plugin indentation
vim.cmd("filetype plugin indent on")

-- Enable syntax highlighting
vim.cmd("syntax on")

-- Highlight extra whitespace in red
vim.cmd("highlight ExtraWhitespace ctermbg=red guibg=red")
vim.cmd("match ExtraWhitespace /\\s\\+$/")

-- Key mappings
local opts = { noremap = true, silent = true }
vim.api.nvim_set_keymap("n", ",1", ":b!1<CR>", opts)
vim.api.nvim_set_keymap("n", ",2", ":b!2<CR>", opts)
vim.api.nvim_set_keymap("n", ",3", ":b!3<CR>", opts)
vim.api.nvim_set_keymap("n", ",4", ":b!4<CR>", opts)
vim.api.nvim_set_keymap("n", ",5", ":b!5<CR>", opts)
vim.api.nvim_set_keymap("n", ",6", ":b!6<CR>", opts)
vim.api.nvim_set_keymap("n", ",7", ":b!7<CR>", opts)
vim.api.nvim_set_keymap("n", ",8", ":b!8<CR>", opts)
vim.api.nvim_set_keymap("n", ",9", ":b!9<CR>", opts)
vim.api.nvim_set_keymap("n", ",0", ":b!0<CR>", opts)
vim.api.nvim_set_keymap("n", ",w", ":bw<CR>", opts)

-- Restore the cursor to the last position when reopening a file
vim.api.nvim_create_autocmd("BufReadPost", {
  pattern = "*",
  callback = function()
    local last_pos = vim.fn.line([['"]])
    if last_pos > 0 and last_pos <= vim.fn.line("$") then
      vim.cmd([[normal! g`"]])
    end
  end
})

-- Turn off indent options when edit Makefile
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "mk", "makefile", "Makefile", "make" },
  callback = function()
    vim.opt_local.expandtab = false
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
    vim.opt_local.softtabstop = 4
  end
})

-- Remove the whitespaces when save any file
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*",
  callback = function()
    vim.cmd("%s/\\s\\+$//e")
  end
})

-- Set tags
vim.opt.tags = { "./tags;", "./ctags;" }
