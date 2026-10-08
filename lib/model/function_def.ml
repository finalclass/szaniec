(* Function catalog records. The suggestion contract defines the identity
   and normalization rules. This is not a complexity measurement. *)

type t =
  { id: string
  ; name: string
  ; unit_canonical: string
  ; source_path: string
  ; line: int
  ; col: int
  ; end_line: int
  ; parameters: string list
  ; variables: string list
  ; binding_text: string
  ; body_text: string
  ; normalized_body: string
  ; comment_before: string
  ; kind: string
  ; provenance: string
  ; truncated: bool
  ; source_status: string }

type gap =
  { code: string
  ; path: string
  ; detail: string }

type use_site =
  { caller: string
  ; callee: string
  ; path: string
  ; line: int }

type catalog =
  { snapshot_digest: string
  ; compiler: string
  ; functions: t list
  ; uses: use_site list
  ; gaps: gap list }

let strip_comments (text : string) : string =
  let n = String.length text in
  let buf = Buffer.create n in
  let rec go i =
    if i >= n
    then ()
    else if i + 1 < n && text.[i] = '(' && text.[i + 1] = '*'
    then (
      let rec close j depth =
        if j + 1 >= n
        then n
        else if text.[j] = '(' && text.[j + 1] = '*'
        then close (j + 2) (depth + 1)
        else if text.[j] = '*' && text.[j + 1] = ')'
        then if depth = 0 then j + 2 else close (j + 2) (depth - 1)
        else close (j + 1) depth
      in
      Buffer.add_char buf ' ' ;
      go (close (i + 2) 0) )
    else (
      Buffer.add_char buf text.[i] ;
      go (i + 1) )
  in
  go 0 ;
  Buffer.contents buf

let normalize (text : string) : string =
  let s = strip_comments text in
  let buf = Buffer.create (String.length s) in
  let pending = ref false in
  String.iter
    (fun c ->
      match c with
      | ' '
       |'\t'
       |'\n'
       |'\r' ->
          pending := true
      | _ ->
          if !pending && Buffer.length buf > 0 then Buffer.add_char buf ' ' ;
          pending := false ;
          Buffer.add_char buf c )
    s ;
  String.trim (Buffer.contents buf)

let provenance_of_path (path : string) : string =
  let segs = String.split_on_char '/' path in
  if List.exists (fun s -> String.equal s "test") segs
  then "test"
  else "authored"
