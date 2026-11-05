(* ConformanceEngine: classifies dune stanzas into IDesign components and
   evaluates their declared dependencies against the closed-architecture
   rules and the well-ocaml profile. Pure: no file system, no framework
   knowledge beyond the Profile table. See docs/contracts/rule-catalog.md. *)

open Szaniec_model
open Structure
open Conformance

(* Lowercase, alphanumerics only: "AIAccess" and "ai_access" -> "aiaccess". *)
let key (name : string) : string =
  String.to_seq (String.lowercase_ascii name)
  |> Seq.filter (function
    | 'a' .. 'z'
     |'0' .. '9' ->
        true
    | _ -> false )
  |> String.of_seq

let role_of_name (name : string) : role =
  let k = key name in
  let ends suffix = String.ends_with ~suffix k in
  if ends "manager"
  then Manager
  else if ends "client"
  then Client
  else if ends "engine"
  then Engine
  else if ends "access"
  then Access
  else Utility

(* "AIAccess" -> "ai_access", "WorkProgressManager" -> "work_progress_manager". *)
let snake (name : string) : string =
  let n = String.length name in
  let buf = Buffer.create (n + 8) in
  let upper c = c >= 'A' && c <= 'Z' in
  let lower c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') in
  String.iteri
    (fun i c ->
      if
        i > 0
        && upper c
        && ( lower name.[i - 1]
           || (upper name.[i - 1] && i + 1 < n && lower name.[i + 1]) )
      then Buffer.add_char buf '_' ;
      Buffer.add_char buf (Char.lowercase_ascii c) )
    name ;
  Buffer.contents buf

let family_suffixes =
  [ ("_contract", Contract)
  ; ("_browser", Browser)
  ; ("_spec", Spec)
  ; ("_wire", Wire) ]

let is_family = function
  | Contract
   |Browser
   |Spec
   |Wire ->
      true
  | _ -> false

let classify ~(services : (string, service) Hashtbl.t) (s : stanza) : component
    =
  let make cls role svc =
    { component_name= s.name
    ; component_kind= s.kind
    ; component_class= cls
    ; component_role= role
    ; component_service= Option.map (fun v -> v.service_name) svc
    ; component_at= s.at }
  in
  match s.kind with
  | Executable -> make Root None None
  | Test -> make Test None None
  | Library
    when String.ends_with ~suffix:"_root" (String.lowercase_ascii s.name) ->
      make Root None None
  | Library -> (
      let lower = String.lowercase_ascii s.name in
      let family =
        List.find_map
          (fun (suffix, cls) ->
            if String.ends_with ~suffix lower
            then
              let base =
                String.sub lower 0 (String.length lower - String.length suffix)
              in
              Option.map
                (fun svc -> (cls, svc))
                (Hashtbl.find_opt services (key base))
            else None )
          family_suffixes
      in
      (* Longest "<service>_" prefix on underscore boundaries. *)
      let facet () =
        let segments = String.split_on_char '_' lower in
        let n = List.length segments in
        let rec try_prefix k =
          if k < 1
          then None
          else
            let prefix = List.filteri (fun i _ -> i < k) segments in
            match
              Hashtbl.find_opt services (key (String.concat "_" prefix))
            with
            | Some svc -> Some svc
            | None -> try_prefix (k - 1)
        in
        try_prefix (n - 1)
      in
      let role svc = Some (role_of_name svc.service_name) in
      match Hashtbl.find_opt services (key s.name) with
      | Some svc -> make Service (role svc) (Some svc)
      | None -> (
        match family with
        | Some (cls, svc) -> make cls (role svc) (Some svc)
        | None -> (
          match facet () with
          | Some svc -> make Facet (role svc) (Some svc)
          | None -> make Local (Some (role_of_name s.name)) None ) ) )

(* Components are the same when they belong to one service family, or are
   one local library. *)
let same_component (a : component) (b : component) =
  match (a.component_service, b.component_service) with
  | Some x, Some y -> String.equal x y
  | None, None ->
      a.component_class = Local
      && b.component_class = Local
      && String.equal a.component_name b.component_name
  | _ -> false

let matrix (from_role : role) (to_role : role) : string option =
  match (from_role, to_role) with
  | Client, (Manager | Utility) -> None
  | Client, Client -> Some "ID-CLIENT-CLIENT"
  | Client, Engine -> Some "ID-CLIENT-ENGINE"
  | Client, Access -> Some "ID-CLIENT-ACCESS"
  | Manager, (Engine | Access | Utility) -> None
  | Manager, Manager -> Some "ID-MANAGER-MANAGER"
  | Manager, Client -> Some "ID-MANAGER-CLIENT"
  | Engine, (Access | Utility) -> None
  | Engine, Engine -> Some "ID-ENGINE-ENGINE"
  | Engine, Manager -> Some "ID-ENGINE-MANAGER"
  | Engine, Client -> Some "ID-ENGINE-CLIENT"
  | Access, Utility -> None
  | Access, Access -> Some "ID-ACCESS-ACCESS"
  | Access, (Manager | Engine) -> Some "ID-ACCESS-OUTBOUND"
  | Access, Client -> Some "ID-ACCESS-CLIENT"
  | Utility, Utility -> None
  | Utility, (Manager | Engine | Access | Client) -> Some "ID-UTILITY-BUSINESS"

let role_label = function
  | Some Client -> "Client"
  | Some Manager -> "Manager"
  | Some Engine -> "Engine"
  | Some Access -> "ResourceAccess"
  | Some Utility -> "Utility"
  | None -> "component"

let describe (c : component) =
  match c.component_class with
  | Root when c.component_kind = Library ->
      Printf.sprintf "composition-root library %s" c.component_name
  | Root -> Printf.sprintf "composition root %s" c.component_name
  | Test -> Printf.sprintf "test %s" c.component_name
  | Service ->
      Printf.sprintf
        "%s %s (implementation of %s)"
        (role_label c.component_role)
        c.component_name
        (Option.value ~default:"" c.component_service)
  | Contract
   |Browser
   |Spec
   |Wire
   |Facet ->
      Printf.sprintf
        "%s %s of %s %s"
        (class_name c.component_class)
        c.component_name
        (role_label c.component_role)
        (Option.value ~default:"" c.component_service)
  | Local ->
      Printf.sprintf "%s %s" (role_label c.component_role) c.component_name

let endpoint_of (c : component) =
  { endpoint_name= c.component_name
  ; endpoint_kind= stanza_kind_name c.component_kind
  ; endpoint_class= class_name c.component_class
  ; endpoint_role= c.component_role }

let finding rule ~from_ ~to_ ~at message =
  {rule; from_; to_; at; message; coaching= (Rule_catalog.find rule).coaching}

let version_at_least (v : string) (major, minor) =
  match String.split_on_char '.' v |> List.map int_of_string_opt with
  | Some a :: Some b :: _ -> (a, b) >= (major, minor)
  | _ -> false

let transitive_findings (project : project) : finding list =
  let project_endpoint path =
    { endpoint_name= path
    ; endpoint_kind= "dune-project"
    ; endpoint_class= "project"
    ; endpoint_role= None }
  in
  let setting =
    { endpoint_name= "implicit_transitive_deps"
    ; endpoint_kind= "setting"
    ; endpoint_class= "dune"
    ; endpoint_role= None }
  in
  List.concat_map
    (fun (p : dune_project) ->
      let start = {path= p.project_path; line= 1; col= 1} in
      let f at message =
        [ finding
            "DUNE-TRANSITIVE"
            ~from_:(project_endpoint p.project_path)
            ~to_:setting
            ~at
            message ]
      in
      let lang_ok =
        match p.lang with
        | Some (v, _) -> version_at_least v (3, 17)
        | None -> false
      in
      match (p.lang, p.implicit_transitive_deps) with
      | _, None ->
          f
            (Option.fold ~none:start ~some:snd p.lang)
            ( p.project_path
            ^ " does not declare (implicit_transitive_deps false)" )
      | _, Some (v, at) when v <> "false" ->
          f
            at
            (Printf.sprintf
               "%s declares (implicit_transitive_deps %s)"
               p.project_path
               v )
      | Some (v, at), _ when not lang_ok ->
          f
            at
            (Printf.sprintf
               "%s declares (lang dune %s); (implicit_transitive_deps false) \
                needs 3.17 or newer"
               p.project_path
               v )
      | None, _ -> f start (p.project_path ^ " does not declare (lang dune ...)")
      | _ -> [] )
    project.dune_projects

let evaluate ~(project : project) ~(services : service list) : report =
  let by_key = Hashtbl.create 32 in
  List.iter (fun s -> Hashtbl.replace by_key (key s.service_name) s) services ;
  let components =
    List.map (fun s -> (s, classify ~services:by_key s)) project.stanzas
  in
  let libraries = Hashtbl.create 64 in
  List.iter
    (fun ((s : stanza), c) ->
      if s.kind = Library
      then (
        Hashtbl.replace libraries s.name c ;
        Option.iter (fun p -> Hashtbl.replace libraries p c) s.public_name ) )
    components ;
  (* A dependency resolves to a project library, or, when no stanza
     defines it (generated or absent libraries), to a component classified
     by the same naming conventions. Only exact profile names, dotted names
     and names that classify as a plain Utility are external. *)
  let resolve (d : dependency) : (component * bool) option =
    match Hashtbl.find_opt libraries d.dep_name with
    | Some c -> Some (c, true)
    | None ->
        if Profile.category d.dep_name <> None || String.contains d.dep_name '.'
        then None
        else
          let c =
            classify
              ~services:by_key
              { kind= Library
              ; name= d.dep_name
              ; public_name= None
              ; at= d.dep_at
              ; deps= [] }
          in
          if c.component_class = Local && c.component_role = Some Utility
          then None
          else Some (c, false)
  in
  (* The library through which a service must be reached. *)
  let contract_of svc =
    match
      List.find_opt
        (fun (_, c) ->
          c.component_class = Contract && c.component_service = Some svc )
        components
    with
    | Some (_, c) -> c.component_name
    | None -> snake svc ^ "_contract"
  in
  let findings = ref [] in
  let add f = findings := f :: !findings in
  List.iter
    (fun ((s : stanza), (from : component)) ->
      let exempt = from.component_class = Root || from.component_class = Test in
      let from_ = endpoint_of from in
      List.iter
        (fun (d : dependency) ->
          let at = d.dep_at in
          match resolve d with
          | Some (target, defined) -> (
              let to_ =
                let e = endpoint_of target in
                if defined
                then e
                else {e with endpoint_kind= "undefined-library"}
              in
              let target_text =
                if defined
                then describe target
                else describe target ^ " (not defined in the scanned tree)"
              in
              let reexport_ok =
                is_family from.component_class
                && ( is_family target.component_class
                     && same_component from target
                   || target.component_class = Local
                      && target.component_role = Some Utility )
              in
              if d.dep_source = Re_export && not reexport_ok
              then
                add
                  (finding
                     "DUNE-REEXPORT"
                     ~from_
                     ~to_
                     ~at
                     (Printf.sprintf
                        "%s re-exports %s"
                        (describe from)
                        target_text ) ) ;
              if exempt
              then ()
              else if target.component_class = Root
              then
                add
                  (finding
                     "ROOT-LEAK"
                     ~from_
                     ~to_
                     ~at
                     (Printf.sprintf
                        "%s depends on %s"
                        (describe from)
                        target_text ) )
              else if is_family from.component_class
              then (
                if
                  (* own family, Utility data libraries; never the
                   implementation, a facet or another component *)
                  not
                    ( is_family target.component_class
                      && same_component from target
                    || target.component_class = Local
                       && target.component_role = Some Utility )
                then
                  add
                    (finding
                       "CONTRACT-LEAK"
                       ~from_
                       ~to_
                       ~at
                       (Printf.sprintf
                          "%s depends on %s"
                          (describe from)
                          target_text ) ) )
              else if same_component from target
              then ()
              else
                match target.component_class with
                | Service
                 |Spec
                 |Wire ->
                    let svc =
                      Option.value ~default:"" target.component_service
                    in
                    add
                      (finding
                         "IMPL-CROSS-SERVICE"
                         ~from_
                         ~to_
                         ~at
                         (Printf.sprintf
                            "%s depends on %s; reach %s only through %s"
                            (describe from)
                            target_text
                            svc
                            (contract_of svc) ) )
                | Contract
                 |Browser
                 |Facet
                 |Local -> (
                  match (from.component_role, target.component_role) with
                  | Some a, Some b -> (
                    match matrix a b with
                    | Some rule ->
                        add
                          (finding
                             rule
                             ~from_
                             ~to_
                             ~at
                             (Printf.sprintf
                                "%s depends on %s"
                                (describe from)
                                target_text ) )
                    | None -> () )
                  | _ -> () )
                | Root
                 |Test ->
                    () )
          | None -> (
              let category = Profile.category d.dep_name in
              let to_ =
                { endpoint_name= d.dep_name
                ; endpoint_kind= "external"
                ; endpoint_class=
                    ( match category with
                    | Some c -> "external:" ^ Profile.category_name c
                    | None -> "external" )
                ; endpoint_role= None }
              in
              if
                d.dep_source = Re_export
                && not (is_family from.component_class && category = None)
              then
                add
                  (finding
                     "DUNE-REEXPORT"
                     ~from_
                     ~to_
                     ~at
                     (Printf.sprintf
                        "%s re-exports %s"
                        (describe from)
                        d.dep_name ) ) ;
              match category with
              | Some c
                when (not exempt)
                     && not
                          (Profile.allowed
                             c
                             ~contract_family:(is_family from.component_class)
                             ~role:from.component_role ) ->
                  add
                    (finding
                       (Profile.rule c)
                       ~from_
                       ~to_
                       ~at
                       (Printf.sprintf
                          "%s uses %s library %s"
                          (describe from)
                          (Profile.category_name c)
                          d.dep_name ) )
              | _ -> () ) )
        s.deps )
    components ;
  List.iter
    (fun (u : unsupported) ->
      add
        (finding
           "DUNE-UNSUPPORTED"
           ~from_:
             { endpoint_name= u.owner
             ; endpoint_kind= u.owner_kind
             ; endpoint_class=
                 ( match Hashtbl.find_opt libraries u.owner with
                 | Some c when u.owner_kind <> "directory" ->
                     class_name c.component_class
                 | _ -> u.owner_kind )
             ; endpoint_role= None }
           ~to_:
             { endpoint_name= u.construct
             ; endpoint_kind= "construct"
             ; endpoint_class= "dune"
             ; endpoint_role= None }
           ~at:u.unsupported_at
           u.detail ) )
    project.unsupported ;
  List.iter add (transitive_findings project) ;
  let order (a : finding) (b : finding) =
    compare
      (a.at.path, a.at.line, a.at.col, a.rule, a.to_.endpoint_name)
      (b.at.path, b.at.line, b.at.col, b.rule, b.to_.endpoint_name)
  in
  { project= project.root
  ; profile= Profile.name
  ; services=
      List.sort (fun a b -> compare a.service_name b.service_name) services
  ; components= List.map snd components
  ; findings= List.sort_uniq order !findings }
