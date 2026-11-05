(* S-expressions in dune syntax, with 1-based line/column positions.

   Supported: unquoted atoms, quoted strings (escapes and "\|" / "\>"
   block strings), line comments ";", block comments "#| ... |#"
   (nesting) and datum comments "#;". Anything else is a parse error. *)

type pos =
  { line: int
  ; col: int }

type t =
  | Atom of string * pos
  | Quoted of string * pos
  | List of t list * pos

exception Error of pos * string

let pos_of = function
  | Atom (_, p)
   |Quoted (_, p)
   |List (_, p) ->
      p

type lexer =
  { text: string
  ; mutable i: int
  ; mutable line: int
  ; mutable bol: int (* index of the first character of the line *) }

let here lx = {line= lx.line; col= lx.i - lx.bol + 1}

let peek lx k =
  if lx.i + k < String.length lx.text then Some lx.text.[lx.i + k] else None

let advance lx =
  if lx.text.[lx.i] = '\n'
  then (
    lx.line <- lx.line + 1 ;
    lx.bol <- lx.i + 1 ) ;
  lx.i <- lx.i + 1

let eof lx = lx.i >= String.length lx.text

let is_atom_char = function
  | ' '
   |'\t'
   |'\n'
   |'\r'
   |'\012'
   |'('
   |')'
   |'"'
   |';' ->
      false
  | _ -> true

let rec skip_block_comment lx start depth =
  if eof lx
  then raise (Error (start, "unterminated block comment"))
  else
    match (peek lx 0, peek lx 1) with
    | Some '|', Some '#' ->
        advance lx ;
        advance lx ;
        if depth > 1 then skip_block_comment lx start (depth - 1)
    | Some '#', Some '|' ->
        advance lx ;
        advance lx ;
        skip_block_comment lx start (depth + 1)
    | Some '"', _ ->
        ignore (read_quoted lx) ;
        skip_block_comment lx start depth
    | _ ->
        advance lx ;
        skip_block_comment lx start depth

and read_quoted lx =
  let start = here lx in
  advance lx ;
  let buf = Buffer.create 16 in
  let rec loop () =
    if eof lx
    then raise (Error (start, "unterminated string"))
    else
      match lx.text.[lx.i] with
      | '"' -> advance lx
      | '\\' -> (
          advance lx ;
          if eof lx then raise (Error (start, "unterminated string")) ;
          let c = lx.text.[lx.i] in
          match c with
          | 'n' ->
              Buffer.add_char buf '\n' ;
              advance lx ;
              loop ()
          | 't' ->
              Buffer.add_char buf '\t' ;
              advance lx ;
              loop ()
          | 'r' ->
              Buffer.add_char buf '\r' ;
              advance lx ;
              loop ()
          | 'b' ->
              Buffer.add_char buf '\b' ;
              advance lx ;
              loop ()
          | '\\'
           |'"'
           |'%' ->
              Buffer.add_char buf c ;
              advance lx ;
              loop ()
          | '\n' ->
              (* line continuation: skip leading blanks of the next line *)
              advance lx ;
              while
                (not (eof lx)) && (lx.text.[lx.i] = ' ' || lx.text.[lx.i] = '\t')
              do
                advance lx
              done ;
              loop ()
          | '0' .. '9' ->
              let digits = ref 0 and value = ref 0 in
              while
                !digits < 3
                && (not (eof lx))
                && lx.text.[lx.i] >= '0'
                && lx.text.[lx.i] <= '9'
              do
                value := (!value * 10) + Char.code lx.text.[lx.i] - 48 ;
                incr digits ;
                advance lx
              done ;
              if !digits <> 3 || !value > 255
              then raise (Error (here lx, "invalid decimal escape")) ;
              Buffer.add_char buf (Char.chr !value) ;
              loop ()
          | 'x' ->
              advance lx ;
              let hex k =
                match peek lx k with
                | Some ('0' .. '9' | 'a' .. 'f' | 'A' .. 'F') -> true
                | _ -> false
              in
              if not (hex 0 && hex 1)
              then raise (Error (here lx, "invalid hexadecimal escape")) ;
              Buffer.add_char
                buf
                (Char.chr (int_of_string ("0x" ^ String.sub lx.text lx.i 2))) ;
              advance lx ;
              advance lx ;
              loop ()
          | _ ->
              (* dune keeps unknown escapes verbatim *)
              Buffer.add_char buf '\\' ;
              loop () )
      | _ ->
          advance lx ;
          Buffer.add_char buf lx.text.[lx.i - 1] ;
          loop ()
  in
  loop () ;
  Quoted (Buffer.contents buf, start)

(* "\| text" and "\> text" lines: the rest of the line is the string;
   consecutive such lines are joined. *)
let read_block_string lx =
  let start = here lx in
  let buf = Buffer.create 32 in
  let rec line first =
    (* at '"' *)
    advance lx ;
    advance lx ;
    (* "\|" and "\>" lines are both kept verbatim: escapes in "\>" lines
       never affect library names. *)
    advance lx ;
    if not first then Buffer.add_char buf '\n' ;
    let from = lx.i in
    while (not (eof lx)) && lx.text.[lx.i] <> '\n' do
      advance lx
    done ;
    let content = String.sub lx.text from (lx.i - from) in
    let content =
      if String.length content > 0 && content.[0] = ' '
      then String.sub content 1 (String.length content - 1)
      else content
    in
    Buffer.add_string buf content ;
    (* look ahead for another block-string line *)
    let save_i = lx.i and save_line = lx.line and save_bol = lx.bol in
    let rec blanks () =
      match peek lx 0 with
      | Some (' ' | '\t' | '\n' | '\r') ->
          advance lx ;
          blanks ()
      | _ -> ()
    in
    blanks () ;
    match (peek lx 0, peek lx 1, peek lx 2) with
    | Some '"', Some '\\', Some ('|' | '>') -> line false
    | _ ->
        lx.i <- save_i ;
        lx.line <- save_line ;
        lx.bol <- save_bol
  in
  line true ;
  Quoted (Buffer.contents buf, start)

(* Read the next datum, or None at end of input / before ')'. *)
let rec next lx : t option =
  if eof lx
  then None
  else
    match lx.text.[lx.i] with
    | ' '
     |'\t'
     |'\n'
     |'\r'
     |'\012' ->
        advance lx ;
        next lx
    | ';' ->
        while (not (eof lx)) && lx.text.[lx.i] <> '\n' do
          advance lx
        done ;
        next lx
    | '#' when peek lx 1 = Some '|' ->
        let start = here lx in
        advance lx ;
        advance lx ;
        skip_block_comment lx start 1 ;
        next lx
    | '#' when peek lx 1 = Some ';' -> (
        let start = here lx in
        advance lx ;
        advance lx ;
        match next lx with
        | None -> raise (Error (start, "datum comment without a datum"))
        | Some _ -> next lx )
    | '(' ->
        let start = here lx in
        advance lx ;
        let items = ref [] in
        let rec loop () =
          match next lx with
          | Some item ->
              items := item :: !items ;
              loop ()
          | None ->
              if eof lx
              then raise (Error (start, "unclosed parenthesis"))
              else advance lx (* ')' *)
        in
        loop () ;
        Some (List (List.rev !items, start))
    | ')' -> None
    | '"' -> (
      match (peek lx 1, peek lx 2) with
      | Some '\\', Some ('|' | '>') -> Some (read_block_string lx)
      | _ -> Some (read_quoted lx) )
    | _ ->
        let start = here lx in
        let from = lx.i in
        while (not (eof lx)) && is_atom_char lx.text.[lx.i] do
          advance lx
        done ;
        Some (Atom (String.sub lx.text from (lx.i - from), start))

let parse_string (text : string) : t list =
  let lx = {text; i= 0; line= 1; bol= 0} in
  let rec loop acc =
    match next lx with
    | Some d -> loop (d :: acc)
    | None ->
        if eof lx
        then List.rev acc
        else raise (Error (here lx, "unexpected closing parenthesis"))
  in
  loop []
