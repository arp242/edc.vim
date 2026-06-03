scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

fun! edc#init() abort
	if &filetype == 'gitcommit'
		return
	endif

	" Load file(s).
	let b:edc_rules = {}
	for l:v in edc#load_files()
		if l:v[0] isnot '' && edc#match(l:v[0])
			call extend(b:edc_rules, l:v[1])
		endif
	endfor

	" No rules, no point to continue.
	if len(b:edc_rules) is# 0
		unlet b:edc_rules
		return
	endif

	" Convert/validate values.
	for l:k in keys(b:edc_rules)
		" Nothing to convert.
		if get(s:conv, l:k, 0) is 0 || b:edc_rules[l:k] is# 'unset'
			continue
		endif

		try
			let b:edc_rules[l:k] = s:conv[l:k](b:edc_rules[l:k])
		catch
			unlet b:edc_rules[l:k]
			call s:err('%s: %s', l:k, v:exception)
		endtry
	endfor

	" Apply values.
	let b:edc_save = {}
	let l:unknown = []
	for [l:rule, l:val] in items(b:edc_rules)
		if s:apply(l:rule, l:val)
			call add(l:unknown, l:rule)
		endif
	endfor

	if len(l:unknown) > 0
		let l:err = printf('unknown rules: %s', join(l:unknown, ', '))
		if get(g:, 'edc_ignore', 1)
		if !exists('b:edc_errors')
			let b:edc_errors = []
		endif
		call add(b:edc_errors, l:err)
		else
			call s:err(l:err)
		endif
	endif
endfun

" Load all .editorconfig files until there's one with root = true.
fun! edc#load_files() abort
	let l:ret = []

	" [
	"    ["*":           {indent_style: 'tab'}],
	"    ["*.{txt,csv}": {indent_style: 'space'}],
	" ]
	for l:path in findfile('.editorconfig', '.;', -1)
		let [l:conf, l:root] = s:parse(l:path)

		" Merge with previous value, if any.
		for l:v in l:conf
			let l:found = 0
			for l:ex in l:ret
				if l:ex[0] is# l:v[0]
					call extend(l:ex[1], l:v[1])
					let l:found = 1
				endif
			endfor

			if l:found is# 0 && len(l:v) > 0
				call add(l:ret, l:v)
			endif
		endfor

		if l:root
			let b:edc_root = fnamemodify(l:path, ':p:h')
			break
		endif
	endfor

	return l:ret
endfun

" Parse a single .editorconfig file, sections are returned in the order they're
" found:
"
"   [
"      ["*":           {indent_style: 'tab'}],
"      ["*.{txt,csv}": {indent_style: 'space'}],
"   ]
"
" https://editorconfig.org/#file-format-details
" https://docs.python.org/2/library/configparser.html
fun! s:parse(path) abort
	let l:ret = []
	let l:section = []
	let l:root = 0

	let l:lines = readfile(a:path)
	for l:i in range(len(l:lines))
		let l:line = trim(l:lines[l:i])

		" Remove everything after comment character. Only ; can be used for
		" inline comments and must be preceded by whitespace.
		let l:c = match(l:line, '\s;')
		if l:c > -1
			let l:line = l:line[:l:c - 1]
		endif

		" Skip blank lines and comments.
		if l:line is# '' || l:line[0] is# '#' || l:line[0] is# ';'
			continue
		end

		" Start section.
		if l:line[0] is# '[' && l:line[len(l:line) - 1] is# ']'
			if l:section != []
				call add(l:ret, l:section)
			endif
			let l:section = [trim(trim(l:line, '[]')), {}]
			continue
		endif

		" Line continuation.
		if match(l:lines[l:i], '^\s') > -1
			let l:section[1][l:key] .=  ' ' . tolower(l:line)
			continue
		endif

		" Split key and value.
		if stridx(l:line, '=') > -1
			let l:chr = '='
		elseif stridx(l:line, ':') > -1
			let l:chr = ':'
		else
			call s:err('%s: could not parse line %d', a:path, l:i)
			continue
		endif

		" Properties and values are case-insensitive.
		let l:split = split(tolower(l:line), l:chr)
		let l:key = trim(l:split[0])

		" Special case for top-level root.
		if l:key is# 'root' && l:section ==# []
			let l:root = 1
			continue
		endif

		let l:section[1][l:key] = trim(join(l:split[1:], l:chr))
	endfor

	call add(l:ret, l:section)
	return [l:ret, l:root]
endfun

" Automatically supported:
" [name]        Matches any single character in name.
"
" TODO:
" {num1..num2}  Matches any integer numbers between num1 and num2, where num1
"               and num2 can be either positive or negative.
" 
" Note: The built-in glob2regpat() comes close, but treats * and ** the same,
" and doesn't support {num1..num2}.
let s:glob_to_reg = [
		"\ [!name] Matches any single character not in name.
		\ ['\[!',       '[^'],
		"\ {s1,s2,s3} Matches any of the strings given (separated by commas).
		\ ['{[^}]*}',   '\="\\%(" . substitute(submatch(0)[1:-2], ",", "\\\\|", "g") . "\\)"'],
		"\ ** Matches any string of characters.
		\ ['\*\*',      '.\\{}'],
		"\ * Matches any string of characters, except path separators (/).
		\ ['\*',        '[^/]\\{}'],
		"\ ? Matches any single character.
		\ ['?',         '.'],
\ ]

" Report if the current filename matches the given pattern.
fun! edc#match(pat) abort
	" Quick match.
	if a:pat is# '*' || a:pat is# '**'
		return 1
	endif

	" TODO: escape other regexp chars?
	let l:pat = escape(a:pat, '.')

	for [l:f, l:r] in s:glob_to_reg
		" Special characters can be escaped with a backslash so they won't be
		" interpreted as wildcard patterns.
		let l:pat = substitute(l:pat, '\\\@<!' . l:f, l:r, 'g')
	endfor

	let b:last_pat = l:pat

	" Note: $ anchor is not spec'd, but most (all?) implementations do it, and
	" intuitively makes sense.
	" https://github.com/editorconfig/editorconfig-core-c/blob/master/src/lib/ec_glob.c#L325
	return match(expand('%:p'), l:pat . '$') > -1
endfun

let s:conv = {
	\ 'indent_style':             {v -> s:val_list(l:v, ['tab', 'space'])},
	\ 'indent_size':              {v -> s:val_int(l:v is# 'tab' ? 0 : l:v)},
	\ 'tab_width':                {v -> s:val_int(l:v)},
	\ 'end_of_line':              {v -> s:val_list(l:v, ['lf', 'cr', 'crlf'])},
	\ 'insert_final_newline':     {v -> s:val_bool(l:v)},
	\ 'trim_trailing_whitespace': {v -> s:val_bool(l:v)},
	\ 'max_line_length':          {v -> s:val_int(l:v is# 'off' ? 0 : l:v)},
	\ }

fun! s:val_list(v, list) abort
	if index(a:list, a:v) > -1
		return a:v
	endif
	throw printf('not an allowed value: %s', a:v)
endfun

fun! s:val_bool(v) abort
	if a:v is? 'true' || a:v is# '1'
		return 1
	elseif a:v is? 'false' || a:v is# '0'
		return 0
	endif
	throw printf('not a bool: %s', a:v)
endfun

fun! s:val_int(v) abort
	if match(a:v, '^\d\+$')
		throw printf('not an int: %s', a:v)
	endif
	return str2nr(a:v)
endfun

" Note: setting name is passed to :execute.
fun! s:save(setting, val)
	if a:val is# 'unset'
		if get(b:edc_save, a:setting, v:none) isnot v:none
			exe printf('let &l:%s = b:edc_save[%s]', a:setting, a:setting) 
		endif
		return 1
	endif

	if get(b:edc_save, a:setting, v:none) isnot v:none
		exe printf('let b:edc_save[%s] = &l:%s', a:setting, a:setting) 
	endif
	return 0
endfun

" https://github.com/editorconfig/editorconfig/wiki/EditorConfig-Properties
"
" TODO: add block_comment, line_comment, block_comment_start, block_comment_end
fun! s:apply(rule, val) abort
	if a:rule is# 'indent_style'
		if s:save('expandtab', a:val)
			return
		endif
		let &l:expandtab = {'tab': 0, 'space': 1}[a:val]

	elseif a:rule is# 'end_of_line'
		if s:save('fileformat', a:val)
			return
		endif
		let &l:fileformat = {'lf': 'unix', 'cr': 'mac', 'crlf': 'dos'}[a:val]

	elseif a:rule is# 'indent_size'
		if s:save('shiftwidth', a:val)
			return
		endif
		let &l:shiftwidth = a:val

	elseif a:rule is# 'tab_width'
		if s:save('tabstop', a:val)
			return
		endif
		let &l:tabstop = a:val

	elseif a:rule is# 'max_line_length'
		if s:save('textwidth', a:val)
			return
		endif
		let &l:textwidth = a:val

	elseif a:rule is# 'charset'
		if s:save('fileencoding', a:val)
			return
		endif

		" TODO: set 'bomb'? Maybe parse value smarter?
		" TODO: why has this started giving errors?
		"let &l:fileencoding = a:val

	elseif a:rule is# 'insert_final_newline'
		if s:save('endofline', a:val) 
			" TODO: restore fixendofline
			"call s:save('fixendofline', a:val)
			return
		endif
		let &l:endofline = a:val
		let &l:fixendofline = 0

	elseif a:rule is# 'trim_trailing_whitespace'
		" TODO: unset
		fun! s:trim_trailing() abort
			let l:save = winsaveview()
			keeppatterns %s/\s\+$//e
			call winrestview(l:save)
		endfun
		autocmd plugin-edc BufWritePre <buffer> call s:trim_trailing()

	else
		return 1
	endif

	return 0
endfun

fun! s:err(msg, ...) abort
	if !exists('b:edc_errors')
		let b:edc_errors = []
	endif

	let l:err = call('printf', [a:msg] + a:000)
	call add(b:edc_errors, l:err)

	if get(g:, 'edc_silent', 0)
		return
	endif
	echohl ErrorMsg
	echom 'edc.vim: ' . l:err
	echohl None
endfun


let &cpo = s:save_cpo
unlet s:save_cpo
