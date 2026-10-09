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
  ; extra_fixture: string option
  ; reapprove: bool
  ; no_rebuild: bool
  ; check_twice: bool }

let sc
    ?(mutations = [])
    ?(add_files = [])
    ?extra_fixture
    ?(reapprove = false)
    ?(no_rebuild = false)
    ?(check_twice = false)
    name =
  {name; mutations; add_files; extra_fixture; reapprove; no_rebuild; check_twice}

let fixture_policy_edited =
  ("szaniec.toml", {|name = "tasks-app"|}, {|name = "tasks-app-edited"|})

let generated_sc ?(mutations = []) ?(add_files = []) ?(check_twice = false) name
    =
  sc
    name
    ~extra_fixture:"generated-contracts"
    ~check_twice
    ~add_files
    ~mutations:
      ( ( "lib/dune"
        , "  contract\n  well"
        , "  contract\n\
          \  contract_data\n\
          \  contract_data_browser\n\
          \  app_server\n\
          \  app_browser\n\
          \  well" )
      :: mutations )

let scenarios =
  [ sc "base-pass" ~check_twice:true
  ; generated_sc
      "generated-codecs-pass"
      ~check_twice:true
      ~add_files:
        [ ( "lib/web_client/generated_codec.ml"
          , {|module Native = App_server.App_service_task_manager
module Browser = App_browser.App_service_task_manager
module Access = App_browser.App_service_task_access
module Engine = App_server.App_service_template_engine
module Data = Contract_data.Task_access.Request
module Browser_data = Contract_data_browser.Template_engine.Request

let native value = Native.Request.from_drut (Native.Request.to_drut (Native.Request.make value))

let browser value = Browser.Request.from_drut (Browser.Request.to_drut (Browser.Request.make value))

let access value = Access.Request.from_drut (Access.Request.to_drut (Access.Request.make value))

let engine value = Engine.Request.from_drut (Engine.Request.to_drut (Engine.Request.make value))

let data value = Data.from_drut (Data.to_drut (Data.make value))

let browser_data value = Browser_data.from_drut (Browser_data.to_drut (Browser_data.make value))

let storage value =
  Native.Request.Storage.from_storage_value
    (Browser.Request.Storage.to_storage_value
       (Browser.Request.Storage.from_storage_value value))

let wire value =
  Browser.Request.Storage.storage_of_wire
    (Native.Request.Storage.wire_of_storage value)

let callback value = List.map Access.Request.to_drut [Access.Request.make value]
|}
          ) ]
  ; generated_sc
      "generated-client-access-proxy"
      ~mutations:
        [ ( "lib/web_client/tasks_page.ml"
          , {|let tasks_handler req =|}
          , {|module Remote = App_browser.App_service_task_access

let create_task title = Remote.Proxy.create ~ctx:ctx_w ~title

let tasks_handler req =|}
          )
        ; ( "lib/web_client/tasks_page.ml"
          , "Task_manager.add ~ctx:ctx_w ~title:req.title"
          , "create_task req.title" ) ]
  ; generated_sc
      "generated-engine-engine-proxy"
      ~mutations:
        [ ( "lib/template_engine/template_engine_impl.ml"
          , {|let expand _ctx text = "{" ^ text ^ "}"|}
          , {|let expand ctx text = App_server.App_service_formatting_engine.Proxy.render ~ctx ~text|}
          )
        ; ( "lib/template_engine/dune"
          , "(libraries contract well formatting_engine_lib)"
          , "(libraries contract well formatting_engine_lib app_server)" ) ]
  ; generated_sc
      "generated-manager-manager-proxy"
      ~mutations:
        [ ( "lib/task_manager/task_manager_impl.ml"
          , {|    Task_access.create ~ctx ~title:req.title|}
          , {|    ignore (App_browser.App_service_notification_manager.Proxy.publish ~ctx ~text:req.title);
    Task_access.create ~ctx ~title:req.title|}
          )
        ; ( "lib/task_manager/dune"
          , "(libraries contract well task_access_lib)"
          , "(libraries contract well task_access_lib app_browser)" ) ]
  ; generated_sc
      "generated-nested-undeclared"
      ~add_files:
        [ ( "lib/web_client/generated_codec.ml"
          , {|let unknown () = App_browser.App_service_task_access.Request.unknown 0
|}
          ) ]
  ; generated_sc
      "generated-provenance-missing"
      ~add_files:
        [ ( "lib/web_client/generated_codec.ml"
          , {|let convert value = App_browser.App_service_task_manager.Request.to_drut value
|}
          ) ]
      ~mutations:
        [ ( "lib/generated_browser/app_service_task_manager.ml"
          , "(* Generated by Well. Do not edit. *)"
          , "" ) ]
  ; sc
      "authored-codec-name"
      ~mutations:
        [ ( "lib/task_access/task_access_impl.ml"
          , {|let spec = Task_access.make_spec (module Impl)|}
          , {|module Tools = struct
  let to_drut title = Task_access.create ~ctx:Well.{session_id= "s"; user_id= None} ~title
end

let spec = Task_access.make_spec (module Impl)|}
          )
        ; ( "lib/web_client/tasks_page.ml"
          , "Task_manager.add ~ctx:ctx_w ~title:req.title"
          , "Task_access_impl.Tools.to_drut req.title" ) ]
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

let verify_generated_contracts work name =
  let open Szaniec_model in
  let policy : Policy.t =
    { name= "tasks-app"
    ; program_roots= ["lib"]
    ; approved_shared_modules= ["App.Clock"]
    ; resources= [] }
  in
  let observation =
    Szaniec_program_access.Ocaml_adapter.observe
      ~project_root:work
      ~program_roots:policy.program_roots
      ~assume_fresh:true
      ()
  in
  let cy =
    match
      Szaniec_architecture_access.Cyrograf.load
        ~project_root:work
        ~program_roots:policy.program_roots
    with
    | Ok cy -> cy
    | Error e -> failwith e
  in
  let interpretation =
    Szaniec_interpretation_engine.Well_adapter.interpret ~policy ~cy observation
  in
  let check condition message = if not condition then failwith message in
  let graph =
    Szaniec_inspection_manager.Inspection_manager.build_callgraph
      ~cy
      ~observation
      ~interpretation
  in
  let has_edge source method_name target target_method =
    List.exists
      (fun (service : Callgraph.service_info) ->
        service.si_name = source
        && List.exists
             (fun (method_ : Callgraph.method_info) ->
               method_.mi_name = method_name
               && List.exists
                    (fun (edge : Callgraph.edge) ->
                      edge.target
                      = Callgraph.Service_method (target, target_method) )
                    method_.mi_calls )
             service.si_methods )
      graph.services
  in
  if name = "generated-manager-manager-proxy"
  then
    check
      (has_edge "Task_manager" "add" "Notification_manager" "publish")
      "browser RPC must retain the original caller and target in the call graph" ;
  if name = "generated-engine-engine-proxy"
  then
    check
      (has_edge "Template_engine" "expand" "Formatting_engine" "render")
      "server RPC must retain the original caller and target in the call graph" ;
  check
    (observation.gaps = [])
    "fresh generated fixture must have complete compiler evidence" ;
  List.iter
    (fun (owner : Interpretation.ownership) ->
      let segment =
        List.hd (List.rev (Canonical.split_dots owner.owner_module))
      in
      let prefix = "App_service_" in
      if Canonical.starts_with ~prefix segment
      then
        if
          name = "generated-provenance-missing"
          && owner.owner_module = "App_browser.App_service_task_manager"
        then (
          check
            (owner.owner_class = Interpretation.Unclassified)
            "unproven wrapper must not be adopted" ;
          check
            (List.exists
               (fun (gap : Observation.gap) ->
                 gap.gap_code = "GAP-AMBIGUOUS-OWNERSHIP"
                 && gap.gap_path
                    = "lib/generated_browser/app_service_task_manager.ml" )
               interpretation.gaps )
            "unproven wrapper must retain a gap" )
        else
          let service =
            String.sub
              segment
              (String.length prefix)
              (String.length segment - String.length prefix)
            |> String.capitalize_ascii
          in
          check
            (owner.owner_class = Interpretation.Contract_of service)
            ( "generated wrapper must retain contract identity: "
            ^ owner.owner_module ) )
    interpretation.ownerships ;
  check
    (not
       (List.exists
          (fun (interaction : Interpretation.interaction) ->
            interaction.kind = Interpretation.ServiceRequest
            && List.mem
                 interaction.to_method
                 [ "make"
                 ; "to_drut"
                 ; "from_drut"
                 ; "to_storage_value"
                 ; "from_storage_value"
                 ; "wire_of_storage"
                 ; "storage_of_wire" ] )
          interpretation.interactions ) )
    "generated message mechanics must not become requests" ;
  if name = "generated-provenance-missing"
  then (
    check
      (List.exists
         (fun (gap : Observation.gap) -> gap.gap_code = "GAP-UNRESOLVED-TARGET")
         interpretation.gaps )
      "calls into an unproven contract must remain unresolved" ;
    check
      (not
         (List.exists
            (fun (interaction : Interpretation.interaction) ->
              interaction.from_owner = "App_browser.App_service_task_manager"
              || interaction.target_module
                 = "App_browser.App_service_task_manager" )
            interpretation.interactions ) )
      "unproven contract must not become a guessed service or implementation" ) ;
  if name = "generated-codecs-pass"
  then (
    check
      (has_edge "Task_manager" "add" "Task_access" "create")
      "conversions must not remove the existing business RPC edge" ;
    check
      (List.for_all
         (fun (service : Callgraph.service_info) ->
           List.for_all
             (fun (method_ : Callgraph.method_info) ->
               List.for_all
                 (fun (edge : Callgraph.edge) ->
                   match edge.target with
                   | Callgraph.Service_method (_, method_name) ->
                       not
                         (List.mem
                            method_name
                            [ "make"
                            ; "to_drut"
                            ; "from_drut"
                            ; "to_storage_value"
                            ; "from_storage_value"
                            ; "wire_of_storage"
                            ; "storage_of_wire" ] )
                   | _ -> true )
                 method_.mi_calls )
             service.si_methods )
         graph.services )
      "message conversions must not become architectural call-graph edges" ;
    List.iter
      (fun target ->
        check
          (List.exists
             (fun (call : Observation.call) -> call.callee = target)
             observation.calls )
          ("codec dependency must remain in compiler evidence: " ^ target) )
      [ "Contract_data.Task_manager.Request.to_drut"
      ; "Contract_data_browser.Task_manager.Request.from_drut"
      ; "App_browser.App_service_task_access.Request.make"
      ; "Contract_data.Task_access.Request.Storage.to_storage_value"
      ; "Contract_data_browser.Template_engine.Request.Storage.storage_of_wire"
      ] ;
    check
      (List.exists
         (fun (reference : Observation.value_ref) ->
           reference.ref_target
           = "App_browser.App_service_task_access.Request.to_drut" )
         observation.value_refs )
      "codec callback must remain executable dependency evidence" ;
    check
      (interpretation.gaps = [])
      "generated conversions must have complete interpretation" )

let run_scenario (exe : string) (fixture : string) (s : scenario) : string =
  let work = prepare_work fixture in
  sync_tree fixture work ;
  Option.iter
    (fun directory ->
      copy_tree
        (Filename.concat
           (Filename.concat (Filename.dirname fixture) directory)
           "lib" )
        (Filename.concat work "lib") )
    s.extra_fixture ;
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
  if s.extra_fixture <> None then verify_generated_contracts work s.name ;
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
          if String.starts_with ~prefix:"RUNNER-ERROR:" actual
          then (
            print_endline "ERROR" ;
            failures := s.name :: !failures ;
            print_string actual )
          else if update
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
