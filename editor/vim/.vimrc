set nu
set autoindent
set cindent
set smartindent
"set textwidth=79
set wrap
"set nowrapscan
"set visualbell
set ruler
set tabstop=4
set shiftwidth=4
set expandtab
set fencs=ucs-bom,utf-8,euc-kr,latin1
set fileencoding=utf-8
"set background=light
"set background=dark
"set ignorecase
set hlsearch
set clipboard=unnamedplus

" Hold pointer at last editted point
au BufReadPost *
\ if line("'\"") > 0 && line("'\"") <= line("$") |
\ exe "norm g`\"" |
\ endif

" Shortcuts
map ,1 :b!1<CR>
map ,2 :b!2<CR>
map ,3 :b!3<CR>
map ,4 :b!4<CR>
map ,5 :b!5<CR>
map ,6 :b!6<CR>
map ,7 :b!7<CR>
map ,8 :b!8<CR>
map ,9 :b!9<CR>
map ,0 :b!0<CR>
map ,w :bw<CR>

" Color schemes
"colorscheme blue
"colorscheme darkblue
"colorscheme default
"colorscheme delek
"colorscheme desert
"colorscheme elflord
"colorscheme evening
"colorscheme gruvbox
"colorscheme koehler
"colorscheme morning
"colorscheme murphy
"colorscheme pablo
"colorscheme peachpuff
"colorscheme ron
"colorscheme shine
"colorscheme slate
"colorscheme torte
"colorscheme zellner
colorscheme jellybeans

"au FileType h   setl tabstop=8 shiftwidth=8 expandtab
autocmd FileType mk,makefile,Makefile,make setl noexpandtab tabstop=4 shiftwidth=4 softtabstop=4
"autocmd FileType c,h,asm,S,s setl tabstop=4 shiftwidth=4 softtabstop=4 expandtab
filetype plugin indent on

syntax on

highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/
autocmd FileType python,c,cpp,java,php,javascript autocmd BufWritePre <buffer> :%s/\s\+$//e

set tags=./tags;,./ctags;
