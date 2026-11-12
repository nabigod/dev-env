if exists('g:portable_devenv_core_loaded')
  finish
endif
let g:portable_devenv_core_loaded = 1

let s:whitespace_filetypes = ['make', 'python', 'c', 'cpp', 'rust']

set number
set autoindent
set cindent
set smartindent
set nowrap
set ruler
set tabstop=4
set shiftwidth=4
set noexpandtab
set fencs=ucs-bom,utf-8,euc-kr,latin1
set fileencoding=utf-8
set hlsearch
if exists('+colorcolumn')
  " 'colorcolumn' is optional in small builds; see :help 'colorcolumn'.
  set colorcolumn=100
endif
set tags=./tags;,./ctags;,./rusty-tags.vi;
set tagrelative
set cpoptions-=d

if has('clipboard')
  " +clipboard is compile-time optional; see :help +clipboard.
  if has('unnamedplus')
    " unnamedplus is selected only when the build exposes the + register.
    set clipboard=unnamedplus
  else
    set clipboard=unnamed
  endif
endif

filetype plugin indent on
syntax enable
colorscheme jellybeans

nnoremap <silent> ,1 :b!1<CR>
nnoremap <silent> ,2 :b!2<CR>
nnoremap <silent> ,3 :b!3<CR>
nnoremap <silent> ,4 :b!4<CR>
nnoremap <silent> ,5 :b!5<CR>
nnoremap <silent> ,6 :b!6<CR>
nnoremap <silent> ,7 :b!7<CR>
nnoremap <silent> ,8 :b!8<CR>
nnoremap <silent> ,9 :b!9<CR>
nnoremap <silent> ,0 :b!0<CR>
nnoremap <silent> ,w :bw<CR>
nnoremap Y yy

highlight ExtraWhitespace ctermbg=red guibg=red

augroup portable_devenv_core
  autocmd!
  autocmd BufReadPost * call s:restore_cursor()
  autocmd BufWinEnter * call s:update_whitespace_match()
  autocmd BufEnter * call s:update_whitespace_match()
  autocmd WinEnter * call s:update_whitespace_match()
  autocmd FileType * call s:update_whitespace_match()
  autocmd FileType mk,makefile,Makefile,make setlocal noexpandtab tabstop=4 shiftwidth=4 softtabstop=4
  autocmd BufWritePre * call s:trim_trailing_whitespace()
augroup END

function! s:restore_cursor() abort
  if line("'\"") > 0 && line("'\"") <= line("$")
    normal! g`"
  endif
endfunction

function! s:is_whitespace_filetype(filetype) abort
  return index(s:whitespace_filetypes, a:filetype) >= 0
endfunction

function! s:update_whitespace_match() abort
  if s:is_whitespace_filetype(&l:filetype)
    match ExtraWhitespace /\s\+$/
  else
    match none
  endif
endfunction

function! s:trim_trailing_whitespace() abort
  if s:is_whitespace_filetype(&l:filetype)
    if exists(':keeppatterns') == 2 && (v:version > 704 || (v:version == 704 && has('patch150')))
      " Patch 7.4.150 fixed :keeppatterns for :s; 7.4.083 only added the command.
      keeppatterns %s/\s\+$//e
    else
      " Older Vim keeps only the current search pattern in this fallback.
      let l:last_search_pattern = @/
      try
        %s/\s\+$//e
      finally
        let @/ = l:last_search_pattern
      endtry
    endif
  endif
endfunction

if has('cscope')
  " +cscope is compile-time optional; see :help +cscope.
  function! s:connect_cscope() abort
    let l:database = findfile('cscope.out', '.;')
    if empty(l:database) && exists('$CSCOPE_DB') && !empty($CSCOPE_DB)
      let l:database = $CSCOPE_DB
    endif
    if !empty(l:database) && filereadable(l:database)
      let l:database = fnamemodify(l:database, ':p')
      let l:database_path = fnamemodify(l:database, ':h')
      if !cscope_connection(2, l:database)
        execute 'cs add ' . fnameescape(l:database) . ' ' . fnameescape(l:database_path)
      endif
    endif
  endfunction

  autocmd portable_devenv_core BufEnter * call s:connect_cscope()
  nnoremap <silent> <C-\>c :cs find c <C-R>=expand("<cword>")<CR><CR>
  nnoremap <silent> <C-\>s :cs find s <C-R>=expand("<cword>")<CR><CR>
  nnoremap <silent> <C-\>g :cs find g <C-R>=expand("<cword>")<CR><CR>
endif
