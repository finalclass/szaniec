(* Acceptance runner for Szaniec.

   Usage: runner.exe <szaniec-binary> <fixture-dir> [--update]

   For every scenario the runner copies the base fixture into a temporary
   directory inside its working directory, applies controlled source
   mutations, runs `szaniec check --json` (plus `approve` where the
   scenario needs it) and compares the exit status and the machine
   readable report with test/acceptance/expected/<scenario>.txt.

   --update (re)writes the expected files instead of comparing. *)

type scenario =
  { name: string
  ; mutations: (string * string * string) list
  ; add_files: (string * string) list
  ; reapprove: bool
  ; no_rebuild: bool
  ; check_twice: bool }

let sc
    ?(mutations = [])
    ?(add_files = [])
    ?(reapprove = false)
    ?(no_rebuild = false)
    ?(check_twice = false)
    name =
  {name; mutations; add_files; reapprove; no_rebuild; check_twice}

let fixture_policy_edited =
  ("szaniec.toml", {|name = "tasks-app"|}, {|name = "tasks-app-edited"|})

let scenarios =
  [ sc "base-pass" ~check_twice:true
  ; sc
      "client-access-direct"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , "Task_manager.add ~ctx:ctx_w ~title:req.title"
          , "Task_access.create ~ctx:ctx_w ~title:req.title" ) ]
  ; sc
      "client-access-via-helper"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|let tasks_handler req =
  ignore req ;
  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;
  0|}
          , {|let create_task title =
  let _task = Task_access.create ~ctx:ctx_w ~title in
  ignore _task ;
  0

let tasks_handler req =
  ignore req ;
  create_task (Shared.render_title "new")|}
          ) ]
  ; sc
      "engine-engine"
      ~mutations:
        [ ( "lib/template_engine/template_engine_impl.ml"
          , {|let expand _ctx text = "{" ^ text ^ "}"|}
          , {|let expand ctx text = "{" ^ Formatting_engine.render ~ctx ~text ^ "}"|}
          ) ]
  ; sc
      "bypass-contract"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|(Task_manager.list ~ctx ~limit:req.limit).tasks|}
          , {|Task_access_impl.Impl.list ctx req|} ) ]
  ; sc
      "shared-unapproved"
      ~add_files:
        [ ( "lib/kit/dune"
          , {|(include_subdirs no)

(library
 (name kit)
 (wrapped false)
 (flags
  (:standard -bin-annot)))
|}
          )
        ; ( "lib/kit/hash.ml"
          , {|let sha (s : string) : string = String.length s |> string_of_int
|}
          ) ]
      ~mutations:
        [ ( "lib/task_manager/dune"
          , "(libraries contract well task_access_lib)"
          , "(libraries contract well task_access_lib kit)" )
        ; ( "lib/formatting_engine/dune"
          , "(libraries contract well)"
          , "(libraries contract well kit)" )
        ; ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    let _h = Hash.sha req.title in
    Task_access.create ~ctx ~title:req.title|}
          )
        ; ( "lib/formatting_engine/formatting_engine_impl.ml"
          , {|  let render _ctx text = String.uppercase_ascii text|}
          , {|  let render _ctx text = String.uppercase_ascii (Hash.sha text)|}
          ) ]
  ; sc
      "shared-by-callback"
      ~add_files:
        [ ( "lib/util/hash.ml"
          , {|let sha (s : string) : string = String.length s |> string_of_int
|}
          ) ]
      ~mutations:
        [ ( "lib/web_client/help_page.ml"
          , {|  let _s = Shared.render_title "help" in|}
          , {|  let _s = Shared.render_title "help" in
  let _mapped = List.map Util.Hash.sha ["help"] in|}
          )
        ; ( "lib/report_client/page.ml"
          , {|let show () = Clock.now ()|}
          , {|let show () =
  let _mapped = List.map Util.Hash.sha ["report"] in
  Clock.now ()|}
          ) ]
  ; sc
      "family-outside-layout"
      ~add_files:[("lib/loose.ml", {|let ping () = 1
|})]
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in|}
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore (Loose.ping ()) ;|}
          ) ]
  ; sc
      "family-foreign-alias"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|module Impl : Task_manager.IMPL = struct
  let list ctx (req : Task_access.ListReq.t) =
    (Task_manager.list ~ctx ~limit:req.limit).tasks|}
          , {|module Priv = Task_access_impl

let through ctx req = Priv.Impl.list ctx req

module Impl : Task_manager.IMPL = struct
  let list ctx (req : Task_access.ListReq.t) =
    through ctx req|}
          ) ]
  ; sc
      "type-only-no-sharing"
      ~add_files:[("lib/shapes/shape.ml", {|type t = {n: int}
|})]
      ~mutations:
        [ ( "lib/web_client/help_page.ml"
          , {|  let _s = Shared.render_title "help" in|}
          , {|  let _s = Shared.render_title "help" in
  let _kind : Shapes.Shape.t = {n= 1} in|}
          )
        ; ( "lib/report_client/page.ml"
          , {|let show () = Clock.now ()|}
          , {|let show () =
  let _kind : Shapes.Shape.t = {n= 2} in
  Clock.now ()|}
          ) ]
  ; sc
      "unapproved-whitelist"
      ~reapprove:true
      ~add_files:
        [ ( "lib/kit/dune"
          , {|(include_subdirs no)

(library
 (name kit)
 (wrapped false)
 (flags
  (:standard -bin-annot)))
|}
          )
        ; ( "lib/kit/hash.ml"
          , {|let sha (s : string) : string = String.length s |> string_of_int
|}
          ) ]
      ~mutations:
        [ ( "szaniec.toml"
          , {|approved_shared_modules = ["App.Clock"]|}
          , {|approved_shared_modules = ["App.Clock", "Hash"]|} )
        ; ( "lib/task_manager/dune"
          , "(libraries contract well task_access_lib)"
          , "(libraries contract well task_access_lib kit)" )
        ; ( "lib/formatting_engine/dune"
          , "(libraries contract well)"
          , "(libraries contract well kit)" )
        ; ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    let _h = Hash.sha req.title in
    Task_access.create ~ctx ~title:req.title|}
          )
        ; ( "lib/formatting_engine/formatting_engine_impl.ml"
          , {|  let render _ctx text = String.uppercase_ascii text|}
          , {|  let render _ctx text = String.uppercase_ascii (Hash.sha text)|}
          ) ]
  ; sc
      "ambiguous-family"
      ~add_files:
        [ ( "lib/task_manager/foreign_bind.ml"
          , {|module I : Task_access.IMPL = struct
  let list _ctx _req = []

  let create _ctx title = {Task_access.Task.id= 0; title}
end

let spec = Task_access.make_spec (module I)
|}
          ) ]
  ; sc
      "unsupported-indirection"
      ~mutations:
        [ ( "lib/web_client/help_page.ml"
          , {|let help_handler req =
  ignore req ;
  let _s = Shared.render_title "help" in
  ignore (Clock.now ()) ;
  ignore _s ;
  0|}
          , {|module type S = sig
  val ping : unit -> int
end

let help_handler req =
  ignore req ;
  let _s = Shared.render_title "help" in
  ignore (Clock.now ()) ;
  let m = (module struct let ping () = 1 end : S) in
  let module M = (val m : S) in
  let _n = M.ping () in
  ignore _s ;
  ignore _n ;
  0|}
          ) ]
    (* Manager -> Engine is allowed. A synchronous Manager -> Manager
       call is not; that case is manager-manager-sync. *)
  ; sc
      "layer-correct-unapproved"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    ignore (Formatting_engine.render ~ctx ~text:req.title);
    Task_access.create ~ctx ~title:req.title|}
          ) ]
  ; sc
      "manager-to-client"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    ignore (Audit_client.record ~ctx ~text:req.title);
    Task_access.create ~ctx ~title:req.title|}
          ) ]
  ; sc
      "manager-to-client-via-helper"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|module Impl : Task_manager.IMPL = struct
  let list ctx (req : Task_access.ListReq.t) =
    (Task_manager.list ~ctx ~limit:req.limit).tasks

  let add ctx (req : Task_manager.AddReq.t) =
    Task_access.create ~ctx ~title:req.title
end|}
          , {|let remember ctx text =
  ignore (Audit_client.record ~ctx ~text)

module Impl : Task_manager.IMPL = struct
  let list ctx (req : Task_access.ListReq.t) =
    (Task_manager.list ~ctx ~limit:req.limit).tasks

  let add ctx (req : Task_manager.AddReq.t) =
    remember ctx req.title ;
    Task_access.create ~ctx ~title:req.title
end|}
          ) ]
  ; sc
      "engine-to-client"
      ~mutations:
        [ ( "lib/formatting_engine/formatting_engine_impl.ml"
          , {|let render _ctx text = String.uppercase_ascii text|}
          , {|let render ctx text =
  ignore (Audit_client.record ~ctx ~text) ;
  String.uppercase_ascii text|}
          ) ]
  ; sc
      "access-to-client"
      ~mutations:
        [ ( "lib/task_access/task_access_impl.ml"
          , {|  let create _ctx title =
    Well.Db.with_conn (Lazy.force pool) @@ fun _db ->|}
          , {|  let create ctx title =
    ignore (Audit_client.record ~ctx ~text:title) ;
    Well.Db.with_conn (Lazy.force pool) @@ fun _db ->|}
          ) ]
  ; sc
      "client-multi-manager"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;|}
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  let _ok = Notification_manager.publish ~ctx:ctx_w ~text:req.title in
  ignore _task ;
  ignore _ok ;|}
          ) ]
  ; sc
      "client-multi-manager-branches"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|let tasks_handler req =
  ignore req ;
  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;
  0|}
          , {|let tasks_handler (req : Well.request) =
  if req.meth = "POST" then (
    let _task = Task_manager.add ~ctx:ctx_w ~title:"new" in
    ignore _task )
  else (
    let _ok = Notification_manager.publish ~ctx:ctx_w ~text:"new" in
    ignore _ok ) ;
  0|}
          ) ]
  ; sc
      "client-multi-manager-handlers"
      ~mutations:
        [ ( "lib/web_client/help_page.ml"
          , {|  let _s = Shared.render_title "help" in|}
          , {|  let _s = Shared.render_title "help" in
  let _ok =
    Notification_manager.publish
      ~ctx:Well.{session_id= "s"; user_id= None}
      ~text:"help"
  in
  ignore _ok ;|}
          ) ]
  ; sc
      "client-multi-manager-helper"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|let tasks_handler req =
  ignore req ;
  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;
  0|}
          , {|let notify text =
  let _ok = Notification_manager.publish ~ctx:ctx_w ~text in
  ignore _ok

let tasks_handler req =
  ignore req ;
  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  notify req.title ;
  ignore _task ;
  0|}
          ) ]
  ; sc
      "client-multi-manager-and-gap"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;|}
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  let _ok = Notification_manager.publish ~ctx:ctx_w ~text:req.title in
  let dispatcher = (fun t -> Task_manager.add ~ctx:ctx_w ~title:t) in
  let _hidden = dispatcher "x" in
  ignore _task ;
  ignore _ok ;
  ignore _hidden ;|}
          ) ]
  ; sc
      "ambiguous-try"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|let tasks_handler req =
  ignore req ;
  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;
  0|}
          , {|let tasks_handler req =
  ignore req ;
  ( try
      let _task = Task_manager.add ~ctx:ctx_w ~title:"new" in
      ignore _task
    with _ ->
      let _ok = Notification_manager.publish ~ctx:ctx_w ~text:"new" in
      ignore _ok ) ;
  0|}
          ) ]
  ; sc
      "manager-manager-sync"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    ignore (Notification_manager.publish ~ctx ~text:req.title);
    Task_access.create ~ctx ~title:req.title|}
          ) ]
  ; sc
      "manager-manager-queued"
      ~mutations:
        [ ( "lib/notification_manager/notification_manager_impl.ml"
          , {|let spec = Notification_manager.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.subscribe Notification_manager.cmd_topic (fun _msg -> ()))

let spec = Notification_manager.make_spec (module Impl)|}
          )
        ; ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    ignore
      (Well.request
         ~cmd:Notification_manager.cmd_topic
         ~reply:Notification_manager.reply_topic
         ~key:"k"
         req.title) ;
    Task_access.create ~ctx ~title:req.title|}
          ) ]
  ; sc
      "queue-fanout"
      ~mutations:
        [ ( "lib/notification_manager/notification_manager_impl.ml"
          , {|let spec = Notification_manager.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.subscribe Notification_manager.cmd_topic (fun _msg -> ()))

let spec = Notification_manager.make_spec (module Impl)|}
          )
        ; ( "lib/task_manager/task_manager_impl.ml"
          , {|let spec = Task_manager.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.subscribe Notification_manager.cmd_topic (fun _msg -> ()))

let spec = Task_manager.make_spec (module Impl)|}
          )
        ; ( "lib/web_client/tasks_page.ml"
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in|}
          , {|  ignore
    (Well.request
       ~cmd:Notification_manager.cmd_topic
       ~reply:Notification_manager.reply_topic
       ~key:"k"
       req.title) ;
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in|}
          ) ]
  ; sc
      "queue-fanout-branches"
      ~mutations:
        [ ( "lib/notification_manager/notification_manager_impl.ml"
          , {|let spec = Notification_manager.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.subscribe Notification_manager.cmd_topic (fun _msg -> ()))

let spec = Notification_manager.make_spec (module Impl)|}
          )
        ; ( "lib/task_manager/task_manager_impl.ml"
          , {|let spec = Task_manager.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.subscribe Task_manager.cmd_topic (fun _msg -> ()))

let spec = Task_manager.make_spec (module Impl)|}
          )
        ; ( "lib/web_client/tasks_page.ml"
          , {|let tasks_handler req =
  ignore req ;
  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;
  0|}
          , {|let tasks_handler (req : Well.request) =
  if req.meth = "POST" then
    ignore
      (Well.request
         ~cmd:Notification_manager.cmd_topic
         ~reply:Notification_manager.reply_topic
         ~key:"k"
         "new")
  else
    ignore
      (Well.request
         ~cmd:Task_manager.cmd_topic
         ~reply:Task_manager.reply_topic
         ~key:"k"
         "new") ;
  ignore req ;
  0|}
          ) ]
  ; sc
      "queue-target-engine"
      ~mutations:
        [ ( "lib/template_engine/template_engine_impl.ml"
          , {|let spec = Template_engine.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.subscribe Template_engine.cmd_topic (fun _msg -> ()))

let spec = Template_engine.make_spec (module Impl)|}
          )
        ; ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    ignore
      (Well.request
         ~cmd:Template_engine.cmd_topic
         ~reply:Template_engine.reply_topic
         ~key:"k"
         req.title) ;
    Task_access.create ~ctx ~title:req.title|}
          ) ]
  ; sc
      "queue-target-access"
      ~mutations:
        [ ( "lib/task_access/task_access_impl.ml"
          , {|let spec = Task_access.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.subscribe Task_access.cmd_topic (fun _msg -> ()))

let spec = Task_access.make_spec (module Impl)|}
          )
        ; ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    ignore
      (Well.request
         ~cmd:Task_access.cmd_topic
         ~reply:Task_access.reply_topic
         ~key:"k"
         req.title) ;
    Task_access.create ~ctx ~title:req.title|}
          ) ]
  ; sc
      "queue-unresolved-topic"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|  let add ctx (req : Task_manager.AddReq.t) =
    Task_access.create ~ctx ~title:req.title|}
          , {|  let add ctx (req : Task_manager.AddReq.t) =
    let topic = Notification_manager.cmd_topic in
    ignore
      (Well.request
         ~cmd:topic
         ~reply:Notification_manager.reply_topic
         ~key:"k"
         req.title) ;
    Task_access.create ~ctx ~title:req.title|}
          ) ]
  ; sc
      "event-publish-client"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in|}
          , {|  Well.publish Notification_manager.event_topic req.title ;
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in|}
          ) ]
  ; sc
      "event-subscribe-engine"
      ~mutations:
        [ ( "lib/template_engine/template_engine_impl.ml"
          , {|let spec = Template_engine.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.MessageBus.once "template" (fun _event -> ()))

let spec = Template_engine.make_spec (module Impl)|}
          ) ]
  ; sc
      "event-publish-access"
      ~mutations:
        [ ( "lib/task_access/task_access_impl.ml"
          , {|  let create _ctx title =|}
          , {|  let create _ctx title =
    ignore (Well.MessageBus.publish "tasks" title) ;|}
          ) ]
  ; sc
      "event-roles-allowed"
      ~mutations:
        [ ( "lib/notification_manager/notification_manager_impl.ml"
          , {|let spec = Notification_manager.make_spec (module Impl)|}
          , {|let () =
  ignore (Well.publish Notification_manager.event_topic "ready")

let spec = Notification_manager.make_spec (module Impl)|}
          )
        ; ( "lib/web_client/tasks_page.ml"
          , {|let ctx_w = Well.{session_id= "s"; user_id= None}|}
          , {|let () =
  ignore (Well.subscribe Notification_manager.event_topic (fun _msg -> ()))

let ctx_w = Well.{session_id= "s"; user_id= None}|}
          ) ]
  ; sc
      "resource-boundary"
      ~mutations:
        [ ( "lib/web_client/help_page.ml"
          , {|  let _s = Shared.render_title "help" in|}
          , {|  let _s = Shared.render_title "help" in
  let _c = Well.Db.with_conn (Well.Db.create_pool ()) (fun _db -> 0) in|}
          ) ]
  ; sc
      "unresolved-call"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in|}
          , {|  let dispatcher = (fun t -> Task_manager.add ~ctx:ctx_w ~title:t) in
  let _task = dispatcher "x" in|}
          ) ]
  ; sc
      "stale-artifacts"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|(* Client layer — page handler calls the TaskManager service *)|}
          , {|(* Client layer — page handler calls the TaskManager service *)
(* edited after the last build *)|}
          ) ]
      ~no_rebuild:true
  ; sc "policy-edited" ~mutations:[fixture_policy_edited] ~reapprove:true
    (* A unit outside every service and client family, called by nobody,
     stays unowned. A page under web_client would be a client. *)
  ; sc
      "unclassified-code"
      ~add_files:
        [ ( "lib/orphan.ml"
          , {|(* In-scope unit with no service, client or composition-root role *)

let ping () = 0
|}
          ) ]
  ; sc
      "violations-and-gaps"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in|}
          , {|  let dispatcher = (fun t -> Task_manager.add ~ctx:ctx_w ~title:t) in
  let _task = dispatcher "x" in|}
          )
        ; ( "lib/web_client/help_page.ml"
          , {|  let _s = Shared.render_title "help" in|}
          , {|  let _s = Shared.render_title "help" in
  let _task =
    Task_access.create ~ctx:Well.{session_id= "s"; user_id= None} ~title:"x" in|}
          ) ] ]

(* ── file helpers ─────────────────────────────────────────────────── *)

let read_file (path : string) : string =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic ;
  s

let write_file (path : string) (content : string) =
  let oc = open_out_bin path in
  output_string oc content ;
  close_out oc

let rec copy_tree (src : string) (dst : string) =
  if Sys.is_directory src
  then (
    ( try Unix.mkdir dst 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
    let entries = Array.to_list (Sys.readdir src) in
    List.iter
      (fun e ->
        if
          e = "."
          || e = ".."
          || e = "_build"
          || (String.length e > 0 && e.[0] = '.')
        then ()
        else copy_tree (Filename.concat src e) (Filename.concat dst e) )
      entries )
  else (
    ( try Unix.unlink dst with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> () ) ;
    let data = read_file src in
    write_file dst data )

let remove_tree (path : string) =
  if Sys.file_exists path
  then ignore (Sys.command ("rm -rf " ^ Filename.quote path))

let replace_once (content : string) (old : string) (new_ : string) : string =
  match
    let len = String.length old in
    let rec go i =
      if i + len > String.length content
      then None
      else if String.sub content i len = old
      then Some i
      else go (i + 1)
    in
    go 0
  with
  | None ->
      Printf.ksprintf
        failwith
        "mutation target not found: %s"
        (String.escaped old)
  | Some i ->
      String.sub content 0 i
      ^ new_
      ^ String.sub
          content
          (i + String.length old)
          (String.length content - i - String.length old)

(* ── process helpers ──────────────────────────────────────────────── *)

let capture (cmd : string) : string * int =
  let stdout_file = Filename.temp_file "szaniec_out" ".txt" in
  let code = Sys.command (cmd ^ " > " ^ Filename.quote stdout_file) in
  let out = read_file stdout_file in
  Sys.remove stdout_file ;
  (out, code)

let run_szaniec (exe : string) (args : string) : string * int =
  capture (Printf.sprintf "%s %s" (Filename.quote exe) args)

(* ── scenario execution ───────────────────────────────────────────── *)

let normalize (out : string) : string =
  (* nothing to normalize today: all paths in reports are relative *)
  out

(* Sync [work] to [fixture]: copy/overwrite all non-_build files, remove
   files that only exist in [work] (e.g. added by an earlier scenario). *)
let rec sync_tree (src : string) (dst : string) =
  if Sys.is_directory src
  then (
    ( try Unix.mkdir dst 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
    let src_entries = Array.to_list (Sys.readdir src) in
    let keep e =
      e <> "."
      && e <> ".."
      && e <> "_build"
      && not (String.length e > 0 && e.[0] = '.')
    in
    let dst_entries =
      ( try Array.to_list (Sys.readdir dst) with
        | Sys_error _ -> [] )
      |> List.filter keep
    in
    let src_names = List.map (fun e -> e) src_entries |> List.filter keep in
    List.iter
      (fun e ->
        if not (List.mem e src_names)
        then
          let p = Filename.concat dst e in
          if Sys.is_directory p
          then ignore (Sys.command ("rm -rf " ^ Filename.quote p))
          else
            try Unix.unlink p with
            | Unix.Unix_error (Unix.ENOENT, _, _) -> () )
      dst_entries ;
    List.iter
      (fun e -> sync_tree (Filename.concat src e) (Filename.concat dst e))
      src_names )
  else (
    ( try Unix.unlink dst with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> () ) ;
    write_file dst (read_file src) )

(* The work directory lives outside any dune-managed temporary directory so
   that nested dune builds resolve their own roots and locks. *)
let temp_root = "/tmp/szaniec-acc-" ^ string_of_int (Unix.getpid ())

let work_dir = Filename.concat temp_root "run"

let work_prepared = ref false

let clean_env_prefix =
  "unset INSIDE_DUNE DUNE_SOURCEROOT DUNE_OCAML_STDLIB DUNE_OCAML_HARDCODED "
  ^ "OCAMLFIND_IGNORE_DUPS_IN BUILD_PATH_PREFIX_MAP OCAMLPATH \
     CAML_LD_LIBRARY_PATH; "

let prepare_work (fixture : string) : string =
  if not !work_prepared
  then (
    remove_tree temp_root ;
    ( try Unix.mkdir temp_root 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
    Unix.mkdir work_dir 0o755 ;
    copy_tree fixture work_dir ;
    (* one clean build so every scenario starts from a complete artifact set *)
    let old_cwd = Sys.getcwd () in
    Unix.chdir work_dir ;
    let _code =
      capture
        ( clean_env_prefix
        ^ "DUNE_CACHE=disabled dune clean && DUNE_CACHE=disabled dune build" )
    in
    Unix.chdir old_cwd ;
    work_prepared := true ) ;
  work_dir

let run_scenario (exe : string) (fixture : string) (s : scenario) : string =
  let work = prepare_work fixture in
  sync_tree fixture work ;
  let flags = "--config szaniec.toml --project-root " ^ work in
  (* approve the base policy first, so later policy edits are detected as
     unapproved changes *)
  if s.reapprove then ignore (run_szaniec exe ("approve " ^ flags)) ;
  List.iter
    (fun (file, old, new_) ->
      let path = Filename.concat work file in
      write_file path (replace_once (read_file path) old new_) )
    s.mutations ;
  List.iter
    (fun (file, content) ->
      let path = Filename.concat work file in
      ( try Unix.mkdir (Filename.dirname path) 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
      write_file path content )
    s.add_files ;
  let check_flags =
    flags ^ (if s.no_rebuild then "" else " --rebuild") ^ " --json"
  in
  let out1, code1 = run_szaniec exe ("check " ^ check_flags) in
  let out2, code2 =
    if s.check_twice
    then run_szaniec exe ("check " ^ check_flags)
    else ("", code1)
  in
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "exit=%d\n" code1) ;
  Buffer.add_string buf (normalize out1) ;
  if s.check_twice
  then (
    Buffer.add_string buf (Printf.sprintf "exit2=%d\n" code2) ;
    Buffer.add_string buf (normalize out2) ;
    if out1 <> out2 || code1 <> code2
    then Buffer.add_string buf "DETERMINISM-FAIL: repeated check differs\n" ) ;
  Buffer.contents buf

(* ── driver ───────────────────────────────────────────────────────── *)

let () =
  if Sys.getenv_opt "SZANIEC_KEEP" = Some "1"
  then ()
  else at_exit (fun () -> remove_tree temp_root)

let () =
  match Sys.argv with
  | exe when Array.length exe >= 3 ->
      let exe = exe.(1) in
      let fixture = Unix.realpath Sys.argv.(2) in
      let expected_dir =
        if Array.length Sys.argv > 3 then Sys.argv.(3) else "expected"
      in
      let update = Array.length Sys.argv > 4 && Sys.argv.(4) = "--update" in
      ( try Unix.mkdir expected_dir 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
      let failures = ref [] in
      List.iter
        (fun s ->
          Printf.printf "scenario %s ... %!" s.name ;
          let actual =
            try run_scenario exe fixture s with
            | Failure msg -> "RUNNER-ERROR: " ^ msg ^ "\n"
          in
          let expected_path = Filename.concat expected_dir (s.name ^ ".txt") in
          if update
          then (
            write_file expected_path actual ;
            print_endline "updated" )
          else
            let expected =
              try read_file expected_path with
              | Sys_error _ -> "<missing>"
            in
            if String.equal expected actual
            then print_endline "ok"
            else (
              print_endline "MISMATCH" ;
              failures := s.name :: !failures ;
              print_string
                ( "--- expected ---\n"
                ^ expected
                ^ "--- actual ---\n"
                ^ actual
                ^ "---\n" ) ) )
        scenarios ;
      if !failures <> []
      then (
        Printf.printf
          "FAILED scenarios: %s\n"
          (String.concat ", " (List.rev !failures)) ;
        exit 1 )
      else if not update
      then print_endline "all scenarios passed"
  | _ ->
      prerr_endline
        "usage: runner.exe <szaniec-binary> <fixture-dir> [--update]" ;
      exit 2
