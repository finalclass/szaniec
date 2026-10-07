(* Cyrograf contract files as the approved-architecture projection of
   services. A .cyrograf file whose stem declares rpc methods is a
   service; its role is inferred from the name suffix. *)

type role =
  | Client
  | Manager
  | Engine
  | Access
  | Utility

let role_to_string = function
  | Client -> "client"
  | Manager -> "manager"
  | Engine -> "engine"
  | Access -> "access"
  | Utility -> "utility"

let role_of_suffix (name : string) : role =
  let lower = String.lowercase_ascii name in
  let ends_with suffix =
    let s = String.length suffix and n = String.length lower in
    n >= s && String.sub lower (n - s) s = suffix
  in
  if ends_with "manager"
  then Manager
  else if ends_with "client"
  then Client
  else if ends_with "engine"
  then Engine
  else if ends_with "access"
  then Access
  else Utility

type method_decl =
  { m_name: string
  ; m_request: string (* request type name from the rpc line *)
  ; m_response: string }

type service =
  { svc_name: string (* cyrograf file stem *)
  ; svc_role: role
  ; svc_methods: method_decl list (* sorted by name *) }

type t = {services: service list} (* sorted by name *)

let lowercase_stem (name : string) : string = String.lowercase_ascii name

(* Service-family matching: a path segment equals the service stem
   ignoring case and underscores ("Task_access" = "taskaccess",
   "FlowAccess" = "flow_access"). *)
let normalize_stem (name : string) : string =
  let buf = Buffer.create (String.length name) in
  String.iter (fun c -> if c <> '_' then Buffer.add_char buf c) name ;
  String.lowercase_ascii (Buffer.contents buf)

let segment_matches_service ~(service : string) (segment : string) : bool =
  String.equal (normalize_stem segment) (normalize_stem service)

(* Parse "rpc name(Req) -> Res" from a .cyrograf file. Anything that is
   not an rpc line is not read by this projection. *)
let parse_rpcs (content : string) : method_decl list =
  let methods = ref [] in
  String.split_on_char '\n' content
  |> List.iter (fun line ->
      let line = String.trim line in
      match String.index_opt line ' ' with
      | Some i when String.sub line 0 i = "rpc" -> (
          let rest =
            String.trim (String.sub line (i + 1) (String.length line - i - 1))
          in
          match (String.index_opt rest '(', String.index_opt rest ')') with
          | Some open_p, Some close_p when open_p > 0 && close_p > open_p -> (
              let name = String.sub rest 0 open_p in
              let req =
                String.trim
                  (String.sub rest (open_p + 1) (close_p - open_p - 1))
              in
              let after =
                String.sub rest (close_p + 1) (String.length rest - close_p - 1)
              in
              match String.index_opt after '-' with
              | Some arrow
                when arrow + 2 <= String.length after
                     && String.sub after arrow 2 = "->" ->
                  let res =
                    String.trim
                      (String.sub
                         after
                         (arrow + 2)
                         (String.length after - arrow - 2) )
                  in
                  let valid_name =
                    String.length name > 0
                    &&
                    match name.[0] with
                    | 'a' .. 'z'
                     |'_' ->
                        true
                    | _ -> false
                  in
                  if valid_name && req <> "" && res <> ""
                  then
                    methods :=
                      {m_name= name; m_request= req; m_response= res}
                      :: !methods
              | _ -> () )
          | _ -> () )
      | _ -> () ) ;
  List.sort (fun a b -> String.compare a.m_name b.m_name) !methods

let load ~(project_root : string) ~(program_roots : string list) :
    (t, string) result =
  (* scan for .cyrograf files under the program roots *)
  let rec scan base rel acc =
    let dir = if rel = "" then base else Filename.concat base rel in
    try
      Array.iter
        (fun e ->
          if e = "." || e = ".."
          then ()
          else if String.length e > 0 && e.[0] = '.'
          then ()
          else if List.mem e ["_build"; "node_modules"]
          then ()
          else if Sys.is_directory (Filename.concat dir e)
          then scan base (if rel = "" then e else Filename.concat rel e) acc
          else if Filename.check_suffix e ".cyrograf"
          then acc := (if rel = "" then e else Filename.concat rel e) :: !acc )
        (Sys.readdir dir)
    with
    | Sys_error _ -> ()
  in
  let files = ref [] in
  List.iter (fun root -> scan project_root root files) program_roots ;
  let services = ref [] in
  List.iter
    (fun rel ->
      let stem = Filename.remove_extension (Filename.basename rel) in
      let content =
        try
          let ic = open_in_bin (Filename.concat project_root rel) in
          let n = in_channel_length ic in
          let s = really_input_string ic n in
          close_in ic ;
          s
        with
        | Sys_error _ -> ""
      in
      match parse_rpcs content with
      | [] -> () (* no rpc methods: not a service *)
      | methods ->
          services :=
            {svc_name= stem; svc_role= role_of_suffix stem; svc_methods= methods}
            :: !services )
    !files ;
  Ok
    { services=
        List.sort (fun a b -> String.compare a.svc_name b.svc_name) !services }
