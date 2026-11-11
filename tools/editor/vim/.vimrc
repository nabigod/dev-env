let s:entry_file = resolve(expand('<sfile>:p'))
let s:common_dir = fnamemodify(s:entry_file, ':h:h') . '/common'
" fnameescape() does not escape commas in the comma-separated 'runtimepath'.
let &runtimepath = escape(s:common_dir, ',\') . ',' . &runtimepath
execute 'source ' . fnameescape(s:common_dir . '/core.vim')
unlet s:common_dir
unlet s:entry_file
