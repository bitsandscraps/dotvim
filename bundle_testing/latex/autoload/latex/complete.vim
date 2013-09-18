" {{{1 latex#complete
let s:completion_type = ''
function! latex#complete(findstart, base)
  "
  " Function is called twice. See |complete-functions| for an explanation.
  "
  if a:findstart
    let line = getline('.')
    let pos = col('.') - 1
    while pos > 0 && line[pos - 1] !~ '\\\|{'
      let pos -= 1
    endwhile

    let line_start = line[:pos-1]
    if line_start =~ '\C\\begin\_\s*{$'
      let s:completion_type = 'begin'
    elseif line_start =~ '\C\\end\_\s*{$'
      let s:completion_type = 'end'
    elseif line_start =~ g:latex#complete#ref_pattern . '$'
      let s:completion_type = 'ref'
    elseif line_start =~ g:latex#complete#cite_pattern . '$'
      let s:completion_type = 'bib'
      " check for multiple citations
      let pos = col('.') - 1
      while pos > 0 && line[pos - 1] !~ '{\|,'
        let pos -= 1
      endwhile
    else
      let s:completion_type = 'command'
      if line[pos - 1] == '\'
        let pos -= 1
      endif
    endif
    return pos
  else
    let suggestions = []
    if s:completion_type == 'begin'
      for entry in g:latex#complete#envs
        if entry.word =~ '^' . escape(a:base, '\')
          if g:latex#complete#close_braces && !s:next_chars_match('^}')
            let entry = copy(entry)
            let entry.abbr = entry.word
            let entry.word = entry.word . '}'
          endif
          call add(suggestions, entry)
        endif
      endfor
    elseif s:completion_type == 'end'
      let env = latex#util#current_env()
      if env != ''
        if g:latex#complete#close_braces && !s:next_chars_match('^\s*[,}]')
          call add(suggestions, {'word': env . '}', 'abbr': env})
        else
          call add(suggestions, env)
        endif
      endif
    elseif s:completion_type == 'command'
      for entry in g:latex#complete#commands
        if entry.word =~ '^' . escape(a:base, '\')
          if entry.word =~ '{'
            let entry.abbr = entry.word[0:-2]
          endif
          call add(suggestions, entry)
        endif
      endfor
    elseif s:completion_type == 'ref'
      let suggestions = s:complete_labels(a:base)
    elseif s:completion_type == 'bib'
      let suggestions = s:complete_bibtex(a:base)
    endif
    return suggestions
  endif
endfunction
" }}}

" {{{1 s:complete_bibtex
function! s:complete_bibtex(regexp)
  if g:latex#complete#bibtex#wild_spaces
    " Treat spaces as '.*' if needed
    let regexp = '.*' . substitute(a:regexp, '\s\+', '\\\&.*', 'g')
  else
    let regexp = a:regexp
  endif

  let res = []
  for m in s:bibtex_search(regexp)
    let type = m['type']   == '' ? '[-]' : '[' . m['type']   . '] '
    let auth = m['author'] == '' ? ''    :       m['author'][:20] . ' '
    let year = m['year']   == '' ? ''    : '(' . m['year']   . ')'
    let w = {
          \ 'word': m['key'],
          \ 'abbr': type . auth . year,
          \ 'menu': m['title']
          \ }

    " Close braces if needed
    if g:latex#complete#close_braces && !s:next_chars_match('^\s*[,}]')
      let w.word = w.word . '}'
    endif

    call add(res, w)
  endfor
  return res
endfunction

" {{{1 s:bstfile
let s:bstfile = expand('<sfile>:p:h') . '/vimcomplete'

" {{{1 s:bibtex_search
function! s:bibtex_search(regexp)
  let res = []

  " Find data from external bib files
  let bibdata = s:find_bibliographies()
  if bibdata != ''
    " Write temporary aux file
    let tmpbase = b:latex#file.root . '/bibtex_search_tmp'
    let auxfile = tmpbase . '.aux'
    let bblfile = tmpbase . '.bbl'
    let blgfile = tmpbase . '.blg'
    call writefile([
          \ '\citation{*}',
          \ '\bibstyle{' . s:bstfile . '}',
          \ '\bibdata{' . bibdata . '}' ],
          \ auxfile)
    let cmd = '!cd ' . b:latex#file.root
          \ . '; bibtex -terse '
          \ . fnamemodify(auxfile, ':t') . ' >/dev/null'
    silent execute cmd
    if !has('gui_running')
      redraw!
    endif

    " Parse temporary aux file
    let lines = split(substitute(join(readfile(bblfile), "\n"),
          \ '\n\n\@!\(\s\=\)\s*\|{\|}', '\1', 'g'), "\n")

    for line in filter(lines, 'v:val =~ a:regexp')
      let matches = matchlist(line,
            \ '^\(.*\)||\(.*\)||\(.*\)||\(.*\)||\(.*\)')
      if !empty(matches) && !empty(matches[1])
        call add(res, {
              \ 'key':    matches[1],
              \ 'type':   matches[2],
              \ 'author': matches[3],
              \ 'year':   matches[4],
              \ 'title':  matches[5],
              \ })
      endif
    endfor

    call delete(auxfile)
    call delete(bblfile)
    call delete(blgfile)
  endif

  " Find data from 'thebibliography' environments
  let lines = readfile(b:latex#file.path)
  if match(lines, '\C\\begin{thebibliography}')
    for line in filter(filter(lines, 'v:val =~ ''\C\\bibitem'''),
          \ 'v:val =~ a:regexp')
      let match = matchlist(line, '\\bibitem{\([^}]*\)')[1]
      call add(res, {
            \ 'key': match,
            \ 'type': '',
            \ 'author': '',
            \ 'year': '',
            \ 'title': match,
            \ })
    endfor
  endif

  return res
endfunction

" {{{1 s:find_bibliographies
function! s:find_bibliographies(...)
  if a:0
    let file = a:1
  else
    let file = b:latex#file.path
  endif

  if !filereadable(file)
    return ''
  endif

  let bibliography_cmds = [
        \ '\\bibliography',
        \ '\\addbibresource',
        \ '\\addglobalbib',
        \ '\\addsectionbib',
        \ ]

  let lines = readfile(file)

  let bibdata_list = []

  for cmd in bibliography_cmds
    let bibdata_list += map(filter(copy(lines),
          \ 'v:val =~ ''\C' . cmd . '\s*{[^}]\+}'''),
          \ 'matchstr(v:val, ''\C' . cmd . '\s*{\zs[^}]\+\ze}'')')
  endfor

  let recurse = s:SIDWrap('find_bibliographies') . '(' .  s:SIDWrap('kpsewhich')

  let bibdata_list += map(filter(copy(lines),
        \ 'v:val =~ ''\C\\\%(input\|include\)\s*{[^}]\+}'''),
        \ recurse . '(matchstr(v:val,'
        \ . '''\C\\\%(input\|include\)\s*{\zs[^}]\+\ze}'')))')

  let bibdata_list += map(filter(copy(lines),
        \ 'v:val =~ ''\C\\\%(input\|include\)\s\+\S\+'''),
        \ recurse . '(matchstr(v:val,'
        \ . '''\C\\\%(input\|include\)\s\+\zs\S\+\ze'')))')

  return join(bibdata_list, ',')
endfunction

" {{{1 s:complete_labels
function! s:complete_labels(regex)
  let labels = s:get_labels(b:latex#file.aux)

  let matches = filter(copy(labels),
        \ 'match(v:val[0], "' . a:regex . '") != -1')

  if empty(matches)
    " Also try to match label and number
    let regex_split = split(a:regex)
    if len(regex_split) > 1
      let base = regex_split[0]
      let number = escape(join(regex_split[1:], ' '), '.')
      let matches = filter(copy(labels),
            \ 'match(v:val[0], "' . base   . '") != -1 &&' .
            \ 'match(v:val[1], "' . number . '") != -1')
    endif
  endif

  if empty(matches)
    " Also try to match number
    let matches = filter(copy(labels),
          \ 'match(v:val[1], "' . a:regex . '") != -1')
  endif

  let suggestions = []
  for m in matches
    let entry = {
          \ 'word': m[0],
          \ 'menu': printf("%7s [p. %s]", '('.m[1].')', m[2])
          \ }
    if g:latex#complete#close_braces && !s:next_chars_match('^\s*[,}]')
      let entry = copy(entry)
      let entry.abbr = entry.word
      let entry.word = entry.word . '}'
    endif
    call add(suggestions, entry)
  endfor

  return suggestions
endfunction

" {{{1 s:get_labels

" s:label_cache is a dictionary that maps filenames to tuples of the form
"
"   [ time, labels, inputs ]
"
" where time is modification time of the cache entry, labels is a list like
" returned by extract_labels, and inputs is a list like returned by
" s:extract_inputs.
let s:label_cache = {}

" s:get_labels compares modification time of each entry in the label cache and
" updates it, if necessary. During traversal of the label cache, all current
" labels are collected and returned.
function! s:get_labels(file)
  if !filereadable(a:file)
    return []
  endif

  " Open file in temporary split window for label extraction.
  if !has_key(s:label_cache , a:file)
        \ || s:label_cache[a:file][0] != getftime(a:file)
    let cmd  = '1sp +let\ labels=s:extract_labels()'
    let cmd .= '| let\ inputs=s:extract_inputs()'
    let cmd .= '| quit! ' . a:file
    silent execute cmd
    let s:label_cache[a:file] = [getftime(a:file), labels, inputs]
  endif

  " We need to create a copy of s:label_cache[fid][1], otherwise all inputs'
  " labels would be added to the current file's label cache upon each
  " completion call, leading to duplicates/triplicates/etc. and decreased
  " performance.  Also, because we don't anything with the list besides
  " matching copies, we can get away with a shallow copy for now.
  let labels = copy(s:label_cache[a:file][1])

  for input in s:label_cache[a:file][2]
    let labels += s:get_labels(input)
  endfor

  return labels
endfunction

" {{{1 s:extract_labels
function! s:extract_labels()
  "
  " Searches the current buffer for commands of the form
  "
  "   \newlabel{name}{{number}{page}.*
  "
  " and returns a list of [name, number, page] tuples.
  "
  let matches = []

  " Parse buffer
  call cursor(1,1)
  let [nl, nc] = searchpos('\\newlabel{', 'ecW')
  while [nl, nc] != [0,0]
    let [ml, mc] = searchpairpos('{', '', '}', 'W')
    if ml == nl && search('{\w*{', 'ce', nl)
      let curname = strpart(getline(nl), nc, mc - nc - 1)

      let nc = getpos('.')[2]
      let [ml, mc]  = searchpairpos('{', '', '}', 'W')
      " Ignore cref entries (because they are duplicates)
      if curname !~ "\@cref" && ml == nl && search('\w*{', 'ce', nl)
        let curnumber = strpart(getline(nl), nc, mc - nc - 1)

        let nc = getpos('.')[2]
        let [ml, mc]  = searchpairpos('{', '', '}', 'W')
        if ml == nl
          let curpage = strpart(getline(nl), nc, mc - nc - 1)
          call add(matches, [curname, curnumber, curpage])
        endif
      endif
    endif

    let [nl, nc] = searchpos( '\\newlabel{', 'ecW' )
  endwhile

  return matches
endfunction

" {{{1 s:extract_inputs
function! s:extract_inputs()
  "
  " Searches the current buffer for \@input{file} entries and returns list of
  " all files.
  "
  let matches = []

  " Parse file
  call cursor(1,1)
  let [nl, nc] = searchpos( '\\@input{', 'ecW' )
  while [nl, nc] != [0,0]
    let [nln, ncn] = searchpairpos( '{', '', '}', 'W' )
    if nln == nl
      call add(matches, s:kpsewhich(strpart(getline(nl), nc, ncn - nc - 1)))
    endif

    let [nl, nc] = searchpos( '\\@input{', 'ecW' )
  endwhile

  " Remove empty strings for nonexistant .aux files
  return filter(matches, 'v:val != ""')
endfunction

  " performance.
  " Also, because we don't anything with the list besides matching copies,
  " we can get away with a shallow copy for now.
" {{{1 s:SIDWrap
let s:SID = matchstr(expand('<sfile>'), '\zs<SNR>\d\+_\ze.*$')
function! s:SIDWrap(func)
  return s:SID . a:func
endfunction

" {{{1 s:kpsewhich
function! s:kpsewhich(file)
  let old_dir = getcwd()
  execute 'lcd ' . b:latex#file.root
  let out = system('kpsewhich "' . a:file . '"')
  execute 'lcd ' . fnameescape(old_dir)

  " If kpsewhich has found something, it returns a non-empty string with a
  " newline at the end; otherwise the string is empty
  if len(out)
    " Remove the trailing newline
    let out = fnamemodify(out[:-2], ':p')
  endif

  return out
endfunction

" {{{1 s:next_chars_match
function! s:next_chars_match(regex)
  return strpart(getline('.'), col('.') - 1) =~ a:regex
endfunction

" {{{1 s:close_environment
let s:bracket_pairs = [
        \ ['(', ')'],
        \ ['\[', '\]'],
        \ ['\\{', '\\}'],
        \ ['|', '|'],
        \ ['\.', '|']
      \ ]
function! s:close_environment()
  " Left/Right pairs
  let [nl, nc] = searchpairpos('\C\\left\>', '', '\C\\right\>',
        \ 'bnW', 'latex#util#in_comment()')
  if nl
    let line = strpart(getline(nl), nc - 1)
    let bracket = matchstr(line, '^\\left\zs\((\|\[\|\\{\||\|\.\)\ze')
    for [open, close] in s:bracket_pairs
      let bracket = substitute(bracket, open, close, 'g')
    endfor
    return '\right' . bracket
  endif

  " Environment
  let env = latex#util#get_env()
  if env == '\['
    return '\]'
  elseif env == '\('
    return '\)'
  elseif env != ''
    return '\end{' . env . '}'
  endif

  " No closure found
  return ''
endfunction

" {{{1 s:wrap_selection
function! s:wrap_selection(wrapper)
  keepjumps normal! `>a}
  execute 'keepjumps normal! `<i\' . a:wrapper . '{'
endfunction

" {{{1 s:wrap_selection_prompt_environment
function! s:wrap_selection_prompt_environment(...)
  let env = input('Environment: ', '',
        \ 'customlist,' . s:SIDWrap('input_complete_environment'))
  if empty(env)
    return
  endif

  " Make sure custom indentation does not interfere
  let ieOld = &indentexpr
  setlocal indentexpr=""

  if visualmode() ==# 'V'
    execute 'keepjumps normal! `>o\end{' . env . '}'
    execute 'keepjumps normal! `<O\begin{' . env . '}'
    " indent and format, if requested.
    if a:0 && a:1
      normal! gv>
      normal! gvgq
    endif
  else
    execute 'keepjumps normal! `>a\end{' . env . '}'
    execute 'keepjumps normal! `<i\begin{' . env . '}'
  endif

  exe "setlocal indentexpr=" . ieOld
endfunction

" {{{1 s:change_environment
function! s:change_environment(new_env)
  let [env, l1, c1, l2, c2] = latex#util#get_env(1)

  if a:new_env == '\[' || a:new_env == '['
    let beg = '\['
    let end = '\]'
    let n1 = 1
    let n2 = 1
  elseif a:new_env == '\(' || a:new_env == '('
    let beg = '\('
    let end = '\)'
    let n1 = 1
    let n2 = 1
  else
    let beg = '\begin{' . a:new_env . '}'
    let end = '\end{' . a:new_env . '}'
    let n1 = len(env) + 7
    let n2 = len(env) + 5
  endif

  let line = getline(l1)
  let line = strpart(line, 0, c1 - 1) . l:beg . strpart(line, c1 + n1)
  call setline(l1, line)
  let line = getline(l2)
  let line = strpart(line, 0, c2 - 1) . l:end . strpart(line, c2 + n2)
  call setline(l2, line)
endfunction

" {{{1 s:change_environment_prompt
function! s:change_environment_prompt()
  let new_env = input('Change ' . latex#util#get_env() . ' for: ', '',
        \ 'customlist,' . s:SIDWrap('input_complete_environment'))
  if empty(new_env)
    return
  else
    call s:change_environment(new_env)
  endif
endfunction

" {{{1 s:change_environment_toggle_star
function! s:change_environment_toggle_star()
  let env = latex#util#get_env()

  if env == '\('
    return
  elseif env == '\['
    let new_env = equation
  elseif env[-1:] == '*'
    let new_env = env[:-2]
  else
    let new_env = env . '*'
  endif

  call s:change_environment(new_env)
endfunction

" {{{1 s:input_complete_environment
function! s:input_complete_environment(lead, cmdline, pos)
  let suggestions = []
  for entry in g:latex#complete#environments
    let env = entry.word
    if env =~ '^' . a:lead
      call add(suggestions, env)
    endif
  endfor
  return suggestions
endfunction

" {{{1 Modeline
" vim:fdm=marker:ff=unix
