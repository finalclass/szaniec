(* Deterministic candidate retrieval. Thresholds are the suggestion contract. *)

open Szaniec_model
module Cy = Szaniec_architecture_access.Cyrograf

type budgets =
  { names: int
  ; pairs: int
  ; responsibility: int
  ; complexity: int
  ; experimental: int
  ; body_chars: int }

let default_budgets =
  { names= 12
  ; pairs= 6
  ; responsibility= 6
  ; complexity= 6
  ; experimental= 6
  ; body_chars= 1200 }

type owned =
  { fn: Function_def.t
  ; service: string option
  ; role: string option
  ; ambiguous: bool }

type name_hit =
  { owned: owned
  ; subject: string
  ; subject_kind: string }

type pair =
  { left: owned
  ; right: owned
  ; relation: string
  ; jaccard: float }

type selection =
  { exact: pair list
  ; names: name_hit list
  ; pairs: pair list
  ; responsibility: owned list
  ; complexity: owned list
  ; predicates: name_hit list
  ; effects: owned list
  ; modes: owned list
  ; comments: owned list
  ; indirections: owned list
  ; vocabulary: (string * string list * owned) list }

let denylist =
  [ "tmp"
  ; "temp"
  ; "data"
  ; "foo"
  ; "bar"
  ; "baz"
  ; "obj"
  ; "item"
  ; "value"
  ; "result"
  ; "flag"
  ; "info"
  ; "thing"
  ; "stuff"
  ; "process"
  ; "handle"
  ; "helper"
  ; "util"
  ; "misc"
  ; "arg"
  ; "args"
  ; "lst"
  ; "list"
  ; "res"
  ; "ret"
  ; "ok"
  ; "xs" ]

let ident_of (raw : string) : string =
  let s =
    match String.index_opt raw ':' with
    | Some i -> String.sub raw (i + 1) (String.length raw - i - 1)
    | None -> raw
  in
  let s =
    if String.length s > 0 && (s.[0] = '~' || s.[0] = '?')
    then String.sub s 1 (String.length s - 1)
    else s
  in
  String.lowercase_ascii s

let uninformative (raw : string) : bool =
  let name = ident_of raw in
  String.length name <= 1 || List.exists (String.equal name) denylist

let take n xs =
  let rec go i acc = function
    | _ when i >= n -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> go (i + 1) (x :: acc) rest
  in
  if n <= 0 then [] else go 0 [] xs

let segments (text : string) : string list =
  let buf = Buffer.create 16 in
  let acc = ref [] in
  let flush () =
    if Buffer.length buf > 0
    then (
      acc := Buffer.contents buf :: !acc ;
      Buffer.clear buf )
  in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z'
       |'A' .. 'Z'
       |'0' .. '9'
       |'_' ->
          Buffer.add_char buf c
      | _ -> flush () )
    text ;
  flush () ;
  List.rev !acc

let owns (services : Cy.t) (fn : Function_def.t) : owned =
  let segs = String.split_on_char '.' fn.Function_def.id in
  let matches =
    List.filter
      (fun (s : Cy.service) ->
        List.exists
          (fun seg -> Cy.segment_matches_service ~service:s.Cy.svc_name seg)
          segs )
      services.Cy.services
  in
  match matches with
  | [s] ->
      { fn
      ; service= Some s.Cy.svc_name
      ; role= Some (Cy.role_to_string s.Cy.svc_role)
      ; ambiguous= false }
  | [] -> {fn; service= None; role= None; ambiguous= false}
  | _ -> {fn; service= None; role= None; ambiguous= true}

let relation (a : owned) (b : owned) : string =
  match (a.ambiguous, b.ambiguous, a.service, b.service) with
  | false, false, Some x, Some y when String.equal x y -> "same-service"
  | false, false, Some _, Some _ -> "distinct-services"
  | _ -> "unclassified"

let service_label (o : owned) : string =
  if o.ambiguous
  then "ambiguous"
  else
    match o.service with
    | Some s -> s
    | None -> "unclassified"

let tokens (text : string) : string list =
  Function_def.normalize text
  |> segments
  |> List.filter_map (fun t ->
      if String.length t >= 3 then Some (String.lowercase_ascii t) else None )
  |> List.sort_uniq String.compare

let jaccard (a : string list) (b : string list) : float =
  let rec inter n xs ys =
    match (xs, ys) with
    | [], _
     |_, [] ->
        n
    | x :: xs, y :: ys ->
        let c = String.compare x y in
        if c = 0
        then inter (n + 1) xs ys
        else if c < 0
        then inter n xs (y :: ys)
        else inter n (x :: xs) ys
  in
  let i = inter 0 a b in
  let u = List.length a + List.length b - i in
  if u = 0 then 0. else float_of_int i /. float_of_int u

let count_substr (hay : string) (needle : string) : int =
  let n = String.length needle in
  if n = 0
  then 0
  else
    let rec go i c =
      if i + n > String.length hay
      then c
      else if String.sub hay i n = needle
      then go (i + n) (c + 1)
      else go (i + 1) c
    in
    go 0 0

let module_prefixes (body : string) : int =
  let rec go i acc seen =
    if i >= String.length body
    then acc
    else
      match body.[i] with
      | 'A' .. 'Z' ->
          let rec end_at j =
            if j >= String.length body
            then j
            else
              match body.[j] with
              | 'A' .. 'Z'
               |'a' .. 'z'
               |'0' .. '9'
               |'_' ->
                  end_at (j + 1)
              | _ -> j
          in
          let j = end_at (i + 1) in
          if j < String.length body && body.[j] = '.'
          then
            let name = String.sub body i (j - i) in
            if List.mem name seen
            then go (j + 1) acc seen
            else go (j + 1) (acc + 1) (name :: seen)
          else go (i + 1) acc seen
      | _ -> go (i + 1) acc seen
  in
  go 0 0 []

let contains_any (text : string) (needles : string list) : bool =
  List.exists (fun n -> count_substr text n > 0) needles

let effect_tokens =
  [ "open_out"
  ; "output_string"
  ; "Unix."
  ; "Sys."
  ; "send"
  ; "save"
  ; "store"
  ; "print_" ]

let format_tokens = ["Printf"; "Format"; "string_of"; "^"]

let responsibility_candidate (fn : Function_def.t) : bool =
  let n = fn.Function_def.normalized_body in
  let body = fn.Function_def.body_text in
  (String.length n >= 180 && module_prefixes body >= 2)
  || (contains_any body effect_tokens && contains_any body format_tokens)

let complexity_candidate (fn : Function_def.t) : bool =
  let body = fn.Function_def.body_text in
  let hits =
    count_substr body "match"
    + count_substr body "if "
    + count_substr body "&&"
    + count_substr body "||"
  in
  let lines = 1 + count_substr body "\n" in
  hits >= 6 || lines >= 35

let predicate_name (raw : string) : bool =
  let name = ident_of raw in
  let has s = count_substr name s > 0 in
  has "not_"
  || has "disable"
  || (String.length name >= 3 && String.sub name 0 3 = "no_")

let pure_looking (name : string) : bool =
  let n = String.lowercase_ascii name in
  let has s =
    (String.length n >= String.length s && String.sub n 0 (String.length s) = s)
    || count_substr n s > 0
  in
  has "lookup"
  || has "get_"
  || has "find_"
  || has "format"
  || has "convert"
  || has "to_"
  || has "of_"
  || has "render"
  || has "show"
  || has "display"

let labelled_params (fn : Function_def.t) : int =
  List.fold_left
    (fun n p ->
      if String.length p > 0 && (p.[0] = '~' || p.[0] = '?') then n + 1 else n )
    0
    fn.Function_def.parameters

let short_forward (fn : Function_def.t) : bool =
  let n = fn.Function_def.normalized_body in
  let padded = " " ^ n ^ " " in
  (* A leading keyword has no space before it, so pad both ends. A local
     binding or branch is not a single forward. *)
  String.length n > 0
  && String.length n < 80
  && (not (contains_any padded [" let "; " match "; " if "; " try "]))
  && (not (contains_any n [";"]))
  && fn.Function_def.kind <> "anonymous"

let is_rpc (services : Cy.t) (o : owned) : bool =
  match o.service with
  | None -> false
  | Some name ->
      List.exists
        (fun (s : Cy.service) ->
          String.equal s.Cy.svc_name name
          && List.exists
               (fun (m : Cy.method_decl) ->
                 String.equal m.Cy.m_name o.fn.Function_def.name )
               s.Cy.svc_methods )
        services.Cy.services

let available (o : owned) : bool =
  String.equal o.fn.Function_def.source_status "available"
  && o.fn.Function_def.normalized_body <> ""

let select
    ~(functions : Function_def.t list)
    ~(services : Cy.t)
    ~(experimental : bool)
    (budgets : budgets) : selection =
  let owned = List.map (owns services) functions |> List.filter available in
  let named =
    List.filter
      (fun o ->
        o.fn.Function_def.kind <> "anonymous" && o.fn.Function_def.name <> "" )
      owned
  in
  let exact_pairs =
    let by_body : (string, owned list) Hashtbl.t = Hashtbl.create 16 in
    List.iter
      (fun o ->
        let key = o.fn.Function_def.normalized_body in
        if String.length key >= 40
        then
          let prev = Hashtbl.find_opt by_body key |> Option.value ~default:[] in
          Hashtbl.replace by_body key (o :: prev) )
      named ;
    let pairs = ref [] in
    Hashtbl.iter
      (fun _ group ->
        let group =
          List.sort
            (fun a b -> String.compare a.fn.Function_def.id b.fn.Function_def.id)
            group
        in
        let rec comb = function
          | []
           |_ :: [] ->
              ()
          | a :: rest ->
              List.iter
                (fun b ->
                  pairs :=
                    {left= a; right= b; relation= relation a b; jaccard= 1.0}
                    :: !pairs )
                rest ;
              comb rest
        in
        comb group )
      by_body ;
    List.sort
      (fun a b ->
        String.compare
          (a.left.fn.id ^ "|" ^ a.right.fn.id)
          (b.left.fn.id ^ "|" ^ b.right.fn.id) )
      !pairs
  in
  let semantic =
    let token_cache = List.map (fun o -> (o, tokens o.fn.body_text)) named in
    let rec pairs acc = function
      | [] -> acc
      | (a, ta) :: rest ->
          let acc =
            List.fold_left
              (fun acc (b, tb) ->
                if
                  String.equal
                    a.fn.Function_def.normalized_body
                    b.fn.Function_def.normalized_body
                then acc
                else if
                  String.length a.fn.normalized_body < 40
                  || String.length b.fn.normalized_body < 40
                then acc
                else if List.length ta < 4 || List.length tb < 4
                then acc
                else
                  let score = jaccard ta tb in
                  if score < 0.45
                  then acc
                  else
                    let left, right =
                      if String.compare a.fn.id b.fn.id <= 0
                      then (a, b)
                      else (b, a)
                    in
                    {left; right; relation= relation left right; jaccard= score}
                    :: acc )
              acc
              rest
          in
          pairs acc rest
    in
    pairs [] token_cache
    |> List.sort (fun a b ->
        let c = compare b.jaccard a.jaccard in
        if c <> 0
        then c
        else
          String.compare
            (a.left.fn.id ^ "|" ^ a.right.fn.id)
            (b.left.fn.id ^ "|" ^ b.right.fn.id) )
    |> take budgets.pairs
  in
  let name_hits =
    let hits = ref [] in
    List.iter
      (fun o ->
        if uninformative o.fn.Function_def.name
        then
          hits :=
            {owned= o; subject= o.fn.Function_def.name; subject_kind= "function"}
            :: !hits ;
        List.iter
          (fun p ->
            if uninformative p
            then
              hits :=
                {owned= o; subject= ident_of p; subject_kind= "parameter"}
                :: !hits )
          o.fn.Function_def.parameters ;
        List.iter
          (fun v ->
            if uninformative v
            then
              hits := {owned= o; subject= v; subject_kind= "variable"} :: !hits )
          o.fn.Function_def.variables )
      named ;
    !hits
    |> List.sort (fun a b ->
        let rank = function
          | "function" -> 0
          | "parameter" -> 1
          | _ -> 2
        in
        compare
          ( rank a.subject_kind
          , a.owned.fn.source_path
          , a.owned.fn.line
          , a.subject )
          ( rank b.subject_kind
          , b.owned.fn.source_path
          , b.owned.fn.line
          , b.subject ) )
    |> take budgets.names
  in
  let by_id (a : owned) (b : owned) =
    String.compare a.fn.Function_def.id b.fn.Function_def.id
  in
  let responsibility =
    named
    |> List.filter (fun o -> responsibility_candidate o.fn)
    |> List.sort by_id
    |> take budgets.responsibility
  in
  let complexity =
    owned
    |> List.filter (fun o -> complexity_candidate o.fn)
    |> List.sort by_id
    |> take budgets.complexity
  in
  let predicates, effects, modes, comments, indirections, vocabulary =
    if not experimental
    then ([], [], [], [], [], [])
    else
      let predicates =
        let hits = ref [] in
        List.iter
          (fun o ->
            if predicate_name o.fn.name
            then
              hits :=
                {owned= o; subject= o.fn.name; subject_kind= "function"}
                :: !hits ;
            List.iter
              (fun p ->
                if predicate_name p
                then
                  hits :=
                    {owned= o; subject= ident_of p; subject_kind= "parameter"}
                    :: !hits )
              o.fn.parameters )
          named ;
        !hits
        |> List.sort (fun a b ->
            compare (a.owned.fn.id, a.subject) (b.owned.fn.id, b.subject) )
        |> take budgets.experimental
      in
      let effects =
        named
        |> List.filter (fun o ->
            pure_looking o.fn.name && contains_any o.fn.body_text effect_tokens )
        |> List.sort by_id
        |> take budgets.experimental
      in
      let modes =
        named
        |> List.filter (fun o -> labelled_params o.fn >= 2)
        |> List.sort by_id
        |> take budgets.experimental
      in
      let comments =
        named
        |> List.filter (fun o -> String.length o.fn.comment_before >= 12)
        |> List.sort by_id
        |> take budgets.experimental
      in
      let indirections =
        named
        |> List.filter (fun o -> short_forward o.fn && not (is_rpc services o))
        |> List.sort by_id
        |> take budgets.experimental
      in
      let vocabulary =
        let by_file : (string, owned list) Hashtbl.t = Hashtbl.create 8 in
        List.iter
          (fun o ->
            let prev =
              Hashtbl.find_opt by_file o.fn.source_path
              |> Option.value ~default:[]
            in
            Hashtbl.replace by_file o.fn.source_path (o :: prev) )
          named ;
        let files =
          Hashtbl.fold (fun path group acc -> (path, group) :: acc) by_file []
          |> List.sort (fun a b -> String.compare (fst a) (fst b))
        in
        List.filter_map
          (fun (path, group) ->
            if List.exists (fun o -> uninformative o.fn.name) group
            then
              let names =
                group
                |> List.map (fun o -> o.fn.Function_def.name)
                |> List.sort_uniq String.compare
                |> take 24
              in
              let anchor = List.sort by_id group |> List.hd in
              Some (path, names, anchor)
            else None )
          files
        |> take budgets.experimental
      in
      (predicates, effects, modes, comments, indirections, vocabulary)
  in
  { exact= exact_pairs
  ; names= name_hits
  ; pairs= semantic
  ; responsibility
  ; complexity
  ; predicates
  ; effects
  ; modes
  ; comments
  ; indirections
  ; vocabulary }
