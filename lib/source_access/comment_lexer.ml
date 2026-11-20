type kind =
  | Line
  | Block
  | Documentation
  | Shebang

type span =
  { kind: kind
  ; start: int
  ; stop: int }

exception Malformed of int * string

type syntax =
  | Ocaml
  | Script of
      { templates: bool
      ; regex: bool }
  | Css
  | Shell
  | Powershell
  | Basic
  | Power_query
  | Batch

let looking_at s i prefix =
  let n = String.length prefix in
  i >= 0 && i + n <= String.length s && String.sub s i n = prefix

let line_end s i =
  match String.index_from_opt s i '\n' with
  | Some j -> j
  | None -> String.length s

let comment_stop s i =
  let stop = line_end s i in
  if stop > i && s.[stop - 1] = '\r' then stop - 1 else stop

let find s from pattern =
  let n = String.length s and m = String.length pattern in
  let rec go i =
    if i + m > n
    then None
    else if looking_at s i pattern
    then Some i
    else go (i + 1)
  in
  go from

let block_end s ~start ~opening ~closing =
  match find s (start + String.length opening) closing with
  | Some j -> j + String.length closing
  | None -> raise (Malformed (start, "unterminated comment"))

let escaped_string_end s ~start ~quote ~escape ~multiline =
  let n = String.length s in
  let rec go i =
    if i >= n || ((not multiline) && s.[i] = '\n')
    then raise (Malformed (start, "unterminated string literal"))
    else if s.[i] = escape
    then go (i + 2)
    else if s.[i] = quote
    then i + 1
    else go (i + 1)
  in
  go (start + 1)

let doubled_string_end s ~start ~quote ~multiline =
  let n = String.length s in
  let rec go i =
    if i >= n || ((not multiline) && s.[i] = '\n')
    then raise (Malformed (start, "unterminated string literal"))
    else if s.[i] = quote && i + 1 < n && s.[i + 1] = quote
    then go (i + 2)
    else if s.[i] = quote
    then i + 1
    else go (i + 1)
  in
  go (start + 1)

let documentation_or_block s ~start ~marker =
  let doc_at = start + String.length marker in
  if
    doc_at < String.length s
    && s.[doc_at] = '*'
    && ( doc_at + 1 >= String.length s
       || not (String.contains "*/)" s.[doc_at + 1]) )
  then Documentation
  else Block

let shebang s =
  if looking_at s 0 "#!"
  then Some {kind= Shebang; start= 0; stop= comment_stop s 0}
  else None

let is_ident_char = function
  | 'a' .. 'z'
   |'A' .. 'Z'
   |'0' .. '9'
   |'_'
   |'$' ->
      true
  | _ -> false

let rec span_while predicate s i =
  if i < String.length s && predicate s.[i]
  then span_while predicate s (i + 1)
  else i

let ocaml_quoted_string s i =
  let n = String.length s in
  let lower = function
    | 'a' .. 'z'
     |'_' ->
        true
    | _ -> false
  in
  let extension = function
    | 'a' .. 'z'
     |'A' .. 'Z'
     |'0' .. '9'
     |'_'
     |'.' ->
        true
    | _ -> false
  in
  if i + 1 >= n || s.[i] <> '{'
  then None
  else
    let id_start =
      if s.[i + 1] = '%'
      then
        let after = span_while extension s (i + 2) in
        if after = i + 2 then None else Some (span_while (( = ) ' ') s after)
      else Some (i + 1)
    in
    match id_start with
    | None -> None
    | Some id_start ->
        let id_stop = span_while lower s id_start in
        if id_stop < n && s.[id_stop] = '|'
        then
          let closing =
            "|" ^ String.sub s id_start (id_stop - id_start) ^ "}"
          in
          match find s (id_stop + 1) closing with
          | Some j -> Some (j + String.length closing)
          | None -> raise (Malformed (i, "unterminated quoted string"))
        else None

let ocaml_string_end s start =
  escaped_string_end s ~start ~quote:'"' ~escape:'\\' ~multiline:true

let ocaml_comment_end s start =
  let n = String.length s in
  let rec go i depth =
    if i >= n
    then raise (Malformed (start, "unterminated comment"))
    else if looking_at s i "*)"
    then if depth = 1 then i + 2 else go (i + 2) (depth - 1)
    else if looking_at s i "(*"
    then go (i + 2) (depth + 1)
    else if looking_at s i "'\"'"
    then go (i + 3) depth
    else if s.[i] = '"'
    then go (ocaml_string_end s i) depth
    else
      match ocaml_quoted_string s i with
      | Some j -> go j depth
      | None -> go (i + 1) depth
  in
  go (start + 2) 1

let ocaml_char_end s i =
  let n = String.length s in
  if i + 1 < n && s.[i + 1] = '\\'
  then
    match String.index_from_opt s (i + 3) '\'' with
    | Some j when j - i <= 6 -> j + 1
    | _ -> i + 1
  else if i + 2 < n && s.[i + 2] = '\'' && s.[i + 1] <> '\n'
  then i + 3
  else i + 1

let ocaml_ident_char c = is_ident_char c || c = '\''

let ocaml s from =
  let n = String.length s in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if looking_at s i "(*"
    then
      let stop = ocaml_comment_end s i in
      let kind =
        if
          looking_at s i "(**"
          && not (looking_at s i "(**)" || looking_at s i "(***")
        then Documentation
        else Block
      in
      go stop ({kind; start= i; stop} :: acc)
    else if s.[i] = '"'
    then go (ocaml_string_end s i) acc
    else if s.[i] = '\''
    then go (ocaml_char_end s i) acc
    else
      match ocaml_quoted_string s i with
      | Some j -> go j acc
      | None ->
          if is_ident_char s.[i]
          then go (span_while ocaml_ident_char s i) acc
          else go (i + 1) acc
  in
  go from []

type previous =
  | Nothing
  | Word of string
  | Punctuation of char

let regex_keywords =
  [ "return"
  ; "typeof"
  ; "case"
  ; "do"
  ; "else"
  ; "in"
  ; "of"
  ; "new"
  ; "delete"
  ; "void"
  ; "throw"
  ; "instanceof"
  ; "yield"
  ; "await" ]

let regex_allowed = function
  | Nothing -> true
  | Word w -> List.mem w regex_keywords
  | Punctuation c -> not (c = ')' || c = ']')

let regex_end s start =
  let n = String.length s in
  let rec go i in_class =
    if i >= n || s.[i] = '\n'
    then raise (Malformed (start, "unterminated regular expression"))
    else
      match s.[i] with
      | '\\' -> go (i + 2) in_class
      | '[' -> go (i + 1) true
      | ']' -> go (i + 1) false
      | '/' when not in_class -> span_while is_ident_char s (i + 1)
      | _ -> go (i + 1) in_class
  in
  go (start + 1) false

type frame =
  | Brace
  | Template_expression of int

let script ~templates ~regex s from =
  let n = String.length s in
  let rec template ~opened i stack prev acc =
    if i >= n
    then raise (Malformed (opened, "unterminated template literal"))
    else if s.[i] = '\\'
    then template ~opened (i + 2) stack prev acc
    else if s.[i] = '`'
    then code (i + 1) stack (Word "`") acc
    else if looking_at s i "${"
    then
      code (i + 2) (Template_expression opened :: stack) (Punctuation '{') acc
    else template ~opened (i + 1) stack prev acc
  and code i stack prev acc =
    if i >= n
    then List.rev acc
    else
      match s.[i] with
      | ' '
       |'\t'
       |'\r'
       |'\n' ->
          code (i + 1) stack prev acc
      | '/' when looking_at s i "//" ->
          let stop = comment_stop s i in
          code stop stack prev ({kind= Line; start= i; stop} :: acc)
      | '/' when looking_at s i "/*" ->
          let stop = block_end s ~start:i ~opening:"/*" ~closing:"*/" in
          let kind = documentation_or_block s ~start:i ~marker:"/*" in
          code stop stack prev ({kind; start= i; stop} :: acc)
      | '/' when regex && regex_allowed prev ->
          code (regex_end s i) stack (Word "/") acc
      | ('\'' | '"') as quote ->
          let stop =
            escaped_string_end s ~start:i ~quote ~escape:'\\' ~multiline:false
          in
          code stop stack (Word "\"") acc
      | '`' when templates -> template ~opened:i (i + 1) stack prev acc
      | '{' -> code (i + 1) (Brace :: stack) (Punctuation '{') acc
      | '}' -> (
        match stack with
        | Template_expression opened :: rest ->
            template ~opened (i + 1) rest prev acc
        | _ :: rest -> code (i + 1) rest (Punctuation '}') acc
        | [] -> code (i + 1) [] (Punctuation '}') acc )
      | c when is_ident_char c ->
          let stop = span_while is_ident_char s i in
          code stop stack (Word (String.sub s i (stop - i))) acc
      | c -> code (i + 1) stack (Punctuation c) acc
  in
  code from [] Nothing []

let css s from =
  let n = String.length s in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if looking_at s i "/*"
    then
      let stop = block_end s ~start:i ~opening:"/*" ~closing:"*/" in
      go
        stop
        ( {kind= documentation_or_block s ~start:i ~marker:"/*"; start= i; stop}
        :: acc )
    else if s.[i] = '"' || s.[i] = '\''
    then
      go
        (escaped_string_end
           s
           ~start:i
           ~quote:s.[i]
           ~escape:'\\'
           ~multiline:false )
        acc
    else go (i + 1) acc
  in
  go from []

let byte_order_mark = "\xEF\xBB\xBF"

let word_start s i separators =
  i = 0
  || (i = String.length byte_order_mark && looking_at s 0 byte_order_mark)
  || String.contains separators s.[i - 1]

let shell_heredoc s i =
  let n = String.length s in
  let after_dash, strip_tabs =
    if i + 2 < n && s.[i + 2] = '-' then (i + 3, true) else (i + 2, false)
  in
  let start = span_while (fun c -> c = ' ' || c = '\t') s after_dash in
  let word c = is_ident_char c && c <> '$' in
  if start < n && (s.[start] = '\'' || s.[start] = '"')
  then
    match String.index_from_opt s (start + 1) s.[start] with
    | Some j ->
        Some (String.sub s (start + 1) (j - start - 1), strip_tabs, j + 1)
    | None -> raise (Malformed (i, "unterminated here-document delimiter"))
  else
    let stop = span_while word s start in
    if stop = start
    then None
    else Some (String.sub s start (stop - start), strip_tabs, stop)

let skip_heredocs s i pending =
  let n = String.length s in
  List.fold_left
    (fun line_start (delimiter, strip_tabs, origin) ->
      let rec scan at =
        if at >= n
        then raise (Malformed (origin, "unterminated here-document"))
        else
          let stop = line_end s at in
          let text = String.sub s at (stop - at) in
          let text =
            if strip_tabs
            then
              let tabs = span_while (( = ) '\t') text 0 in
              String.sub text tabs (String.length text - tabs)
            else text
          in
          let text =
            if String.ends_with ~suffix:"\r" text
            then String.sub text 0 (String.length text - 1)
            else text
          in
          if text = delimiter then min n (stop + 1) else scan (stop + 1)
      in
      scan line_start )
    i
    (List.rev pending)

let balanced_end s start ~opening ~closing =
  let n = String.length s in
  let rec go i depth =
    if i >= n
    then raise (Malformed (start, "unterminated expansion"))
    else if s.[i] = '\\'
    then go (i + 2) depth
    else if s.[i] = opening
    then go (i + 1) (depth + 1)
    else if s.[i] = closing
    then if depth = 1 then i + 1 else go (i + 1) (depth - 1)
    else go (i + 1) depth
  in
  go (start + 1) 1

let shell s from =
  let n = String.length s in
  let rec go i pending acc =
    if i >= n
    then
      if pending = []
      then List.rev acc
      else
        let _, _, origin = List.hd pending in
        raise (Malformed (origin, "unterminated here-document"))
    else
      match s.[i] with
      | '\\' -> go (i + 2) pending acc
      | '\n' when pending <> [] -> go (skip_heredocs s (i + 1) pending) [] acc
      | '\'' -> (
        match String.index_from_opt s (i + 1) '\'' with
        | Some j -> go (j + 1) pending acc
        | None -> raise (Malformed (i, "unterminated string literal")) )
      | '"' ->
          go
            (escaped_string_end
               s
               ~start:i
               ~quote:'"'
               ~escape:'\\'
               ~multiline:true )
            pending
            acc
      | '`' ->
          go
            (escaped_string_end
               s
               ~start:i
               ~quote:'`'
               ~escape:'\\'
               ~multiline:true )
            pending
            acc
      | '$' when looking_at s i "$'" ->
          go
            (escaped_string_end
               s
               ~start:(i + 1)
               ~quote:'\''
               ~escape:'\\'
               ~multiline:true )
            pending
            acc
      | '$' when looking_at s i "${" ->
          go (balanced_end s (i + 1) ~opening:'{' ~closing:'}') pending acc
      | '$' when looking_at s i "$((" ->
          go (balanced_end s (i + 1) ~opening:'(' ~closing:')') pending acc
      | '$' when i + 1 < n && s.[i + 1] = '#' -> go (i + 2) pending acc
      | '<' when looking_at s i "<<<" -> go (i + 3) pending acc
      | '<' when looking_at s i "<<" -> (
        match shell_heredoc s i with
        | Some (delimiter, strip_tabs, stop) ->
            go stop ((delimiter, strip_tabs, i) :: pending) acc
        | None -> go (i + 2) pending acc )
      | '#' when word_start s i " \t\n;&|()<>" ->
          let stop = comment_stop s i in
          go stop pending ({kind= Line; start= i; stop} :: acc)
      | _ -> go (i + 1) pending acc
  in
  go from [] []

let powershell_here_string_end s start quote =
  match find s (start + 2) ("\n" ^ String.make 1 quote ^ "@") with
  | Some j -> j + 3
  | None -> raise (Malformed (start, "unterminated here-string"))

let powershell_string_end s start =
  let n = String.length s in
  let rec go i =
    if i >= n
    then raise (Malformed (start, "unterminated string literal"))
    else if s.[i] = '`'
    then go (i + 2)
    else if s.[i] = '"' && i + 1 < n && s.[i + 1] = '"'
    then go (i + 2)
    else if s.[i] = '"'
    then i + 1
    else go (i + 1)
  in
  go (start + 1)

let powershell s from =
  let n = String.length s in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if looking_at s i "<#"
    then
      let stop = block_end s ~start:i ~opening:"<#" ~closing:"#>" in
      go stop ({kind= Block; start= i; stop} :: acc)
    else if looking_at s i "@\"\n" || looking_at s i "@\"\r\n"
    then go (powershell_here_string_end s i '"') acc
    else if looking_at s i "@'\n" || looking_at s i "@'\r\n"
    then go (powershell_here_string_end s i '\'') acc
    else
      match s.[i] with
      | '`' -> go (i + 2) acc
      | '\'' ->
          go (doubled_string_end s ~start:i ~quote:'\'' ~multiline:true) acc
      | '"' -> go (powershell_string_end s i) acc
      | '#' when word_start s i " \t\r\n;(){}|," ->
          let stop = comment_stop s i in
          go stop ({kind= Line; start= i; stop} :: acc)
      | _ -> go (i + 1) acc
  in
  go from []

let basic s from =
  let n = String.length s in
  let rem_at i =
    i + 3 <= n
    && String.lowercase_ascii (String.sub s i 3) = "rem"
    && (i + 3 = n || String.contains " \t\r\n" s.[i + 3])
  in
  let rec go i statement_start acc =
    if i >= n
    then List.rev acc
    else
      match s.[i] with
      | '\n' -> go (i + 1) true acc
      | ' '
       |'\t'
       |'\r' ->
          go (i + 1) statement_start acc
      | '"' ->
          go
            (doubled_string_end s ~start:i ~quote:'"' ~multiline:false)
            false
            acc
      | '\'' ->
          let stop = comment_stop s i in
          go stop false ({kind= Line; start= i; stop} :: acc)
      | ':' when not (looking_at s i ":=") -> go (i + 1) true acc
      | _ when statement_start && rem_at i ->
          let stop = comment_stop s i in
          go stop false ({kind= Line; start= i; stop} :: acc)
      | c when is_ident_char c -> go (span_while is_ident_char s i) false acc
      | _ -> go (i + 1) false acc
  in
  go from true []

let power_query s from =
  let n = String.length s in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if looking_at s i "//"
    then
      let stop = comment_stop s i in
      go stop ({kind= Line; start= i; stop} :: acc)
    else if looking_at s i "/*"
    then
      let stop = block_end s ~start:i ~opening:"/*" ~closing:"*/" in
      go
        stop
        ( {kind= documentation_or_block s ~start:i ~marker:"/*"; start= i; stop}
        :: acc )
    else if s.[i] = '"'
    then go (doubled_string_end s ~start:i ~quote:'"' ~multiline:true) acc
    else go (i + 1) acc
  in
  go from []

let batch s from =
  let n = String.length s in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else
      let stop = line_end s i in
      let first = span_while (fun c -> c = ' ' || c = '\t' || c = '@') s i in
      let rem =
        first + 3 <= stop
        && String.lowercase_ascii (String.sub s first 3) = "rem"
        && (first + 3 = stop || String.contains " \t\r" s.[first + 3])
      in
      let acc =
        if rem || looking_at s first "::"
        then {kind= Line; start= first; stop= comment_stop s first} :: acc
        else acc
      in
      go (stop + 1) acc
  in
  go from []

let spans syntax s =
  let leading = shebang s in
  let from =
    match leading with
    | Some span -> span.stop
    | None -> 0
  in
  let body =
    match syntax with
    | Ocaml -> ocaml s from
    | Script {templates; regex} -> script ~templates ~regex s from
    | Css -> css s from
    | Shell -> shell s from
    | Powershell -> powershell s from
    | Basic -> basic s from
    | Power_query -> power_query s from
    | Batch -> batch s from
  in
  Option.to_list leading @ body
