let s:entry_file = resolve(expand('<sfile>:p'))
let s:neovim_dir = fnamemodify(s:entry_file, ':h')
let s:common_dir = resolve(s:neovim_dir . '/../common')
let g:portable_devenv_nvim_common_dir = s:common_dir
if has('nvim-0.5')
  " Keep common available after startup; /proc/self/fd avoids Neovim's runtimepath backslash parsing.
  lua << EOF
local common_fd = vim.loop.fs_open(vim.g.portable_devenv_nvim_common_dir, "r", 0)
if common_fd then
  vim.g.portable_devenv_nvim_common_runtime = "/proc/self/fd/" .. common_fd
  vim.g.portable_devenv_nvim_common_fd = common_fd
else
  vim.g.portable_devenv_nvim_common_runtime = vim.g.portable_devenv_nvim_common_dir
end
EOF
  let &runtimepath = g:portable_devenv_nvim_common_runtime . ',' . &runtimepath
else
  let &runtimepath = escape(s:common_dir, ',\') . ',' . &runtimepath
endif
execute 'source ' . fnameescape(s:common_dir . '/core.vim')

if has('nvim-0.5')
  " Neovim 0.5 provides the Lua API used here; see :help lua.
  let g:portable_devenv_neovim_core_path = s:neovim_dir . '/lua/core.lua'
  lua dofile(vim.g.portable_devenv_neovim_core_path)
endif

if exists('g:portable_devenv_nvim_common_fd')
  augroup portable_devenv_nvim_runtime
    autocmd!
    autocmd VimLeavePre * lua vim.loop.fs_close(vim.g.portable_devenv_nvim_common_fd)
  augroup END
endif
