(* CheckClient rendering of the check report: human text grouped by rule,
   or szaniec-check/2 JSON. *)

open Szaniec_model
open Conformance

let role_json = function
  | Some r -> `String (role_name r)
  | None -> `Null

let position_json (p : Structure.position) =
  `Assoc [("path", `String p.path); ("line", `Int p.line); ("col", `Int p.col)]

let endpoint_json (e : endpoint) =
  `Assoc
    [ ("name", `String e.endpoint_name)
    ; ("kind", `String e.endpoint_kind)
    ; ("class", `String e.endpoint_class)
    ; ("role", role_json e.endpoint_role) ]

let status (r : report) = if r.findings = [] then "conforming" else "violations"

let json (r : report) : string =
  let component (c : component) =
    `Assoc
      [ ("name", `String c.component_name)
      ; ("kind", `String (Structure.stanza_kind_name c.component_kind))
      ; ("class", `String (class_name c.component_class))
      ; ("role", role_json c.component_role)
      ; ( "service"
        , match c.component_service with
          | Some s -> `String s
          | None -> `Null )
      ; ("location", position_json c.component_at) ]
  in
  let service (s : Structure.service) =
    `Assoc
      [ ("name", `String s.service_name)
      ; ("source", `String s.service_source)
      ; ("methods", `List (List.map (fun m -> `String m) s.service_methods)) ]
  in
  let finding (f : finding) =
    `Assoc
      [ ("rule", `String f.rule)
      ; ("from", endpoint_json f.from_)
      ; ("to", endpoint_json f.to_)
      ; ("location", position_json f.at)
      ; ("message", `String f.message)
      ; ("coaching", `String f.coaching) ]
  in
  Yojson.Safe.pretty_to_string
    (`Assoc
       [ ("format", `String Version.check_format)
       ; ("status", `String (status r))
       ; ("project", `String r.project)
       ; ("profile", `String r.profile)
       ; ("services", `List (List.map service r.services))
       ; ("components", `List (List.map component r.components))
       ; ("findings", `List (List.map finding r.findings)) ] )
  ^ "\n"

(* Wrap coaching to the terminal width with an indent. *)
let wrap ~indent (text : string) : string =
  let width = 78 - String.length indent in
  let words = String.split_on_char ' ' text |> List.filter (( <> ) "") in
  let buf = Buffer.create (String.length text + 64) in
  let line = ref 0 in
  List.iter
    (fun w ->
      if !line > 0 && !line + 1 + String.length w > width
      then (
        Buffer.add_char buf '\n' ;
        line := 0 ) ;
      if !line = 0
      then Buffer.add_string buf indent
      else Buffer.add_char buf ' ' ;
      Buffer.add_string buf w ;
      line := !line + (if !line = 0 then 0 else 1) + String.length w )
    words ;
  Buffer.contents buf

let text (r : report) : string =
  let buf = Buffer.create 4096 in
  let add fmt = Printf.ksprintf (Buffer.add_string buf) fmt in
  let count kind =
    List.length
      (List.filter
         (fun (c : component) -> c.component_class = kind)
         r.components )
  in
  let plural n one many =
    Printf.sprintf "%d %s" n (if n = 1 then one else many)
  in
  add
    "szaniec check (%s): %s\n  %s, %s, %s, %s, %s\n"
    r.profile
    (status r)
    (plural (List.length r.services) "service" "services")
    (plural
       (List.length
          (List.filter
             (fun (c : component) -> c.component_service <> None)
             r.components ) )
       "service library"
       "service libraries" )
    (plural (count Local) "local library" "local libraries")
    (plural (count Root) "root" "roots")
    (plural (count Test) "test" "tests") ;
  let rules =
    List.sort_uniq compare (List.map (fun (f : finding) -> f.rule) r.findings)
  in
  List.iter
    (fun rule ->
      let fs = List.filter (fun (f : finding) -> f.rule = rule) r.findings in
      add "\n%s (%d)\n" rule (List.length fs) ;
      List.iter
        (fun (f : finding) ->
          add "  %s:%d:%d: %s\n" f.at.path f.at.line f.at.col f.message )
        fs ;
      add "  How to fix:\n%s\n" (wrap ~indent:"    " (List.hd fs).coaching) )
    rules ;
  add
    "\n%d finding(s)%s\n"
    (List.length r.findings)
    ( if rules = []
      then ""
      else
        " in "
        ^ String.concat
            ", "
            (List.map
               (fun rule ->
                 Printf.sprintf
                   "%s %d"
                   rule
                   (List.length
                      (List.filter
                         (fun (f : finding) -> f.rule = rule)
                         r.findings ) ) )
               rules ) ) ;
  Buffer.contents buf
