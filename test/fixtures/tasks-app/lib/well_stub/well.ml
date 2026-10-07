(* Well API stub for this fixture. It mirrors the public surface of the
   Well framework (revision 5c573753367f10d7226f5eaedf1adbeacab2c09d) that
   the fixture uses, so the application type-checks without the real
   framework dependency. Szaniec interprets the framework by canonical
   unit prefixes declared in the policy; the stub plays the role of the
   external `well` library. It is not the real framework and carries no
   runtime behavior. *)

type rpc_ctx =
  { session_id: string
  ; user_id: string option }

type request =
  { meth: string
  ; path: string
  ; body: string }

module Db = struct
  type pool = {file: string}

  type conn = {c: unit}

  let create_pool ?(size = 8) ?(filename = "app.sqlite") () =
    ignore size ;
    {file= filename}

  let with_conn (_p : pool) (f : conn -> 'a) : 'a = f {c= ()}
end

module Service = struct
  type spec =
    { name: string
    ; handler: unit }

  let register (spec : spec) = ignore spec

  let expose name = ignore name
end

let get path handler = ignore (path, handler)

let post path handler = ignore (path, handler)

let form req key =
  ignore req ;
  ignore key ;
  ""

let run () = ()

(* Verified messaging surface. Well.request is a queued command: it
   publishes internally and is not a publication. Topic identity for
   these typed helpers is the value passed in, not the channel string. *)

type topic = {channel: string}

let topic channel _serialize _deserialize =
  ignore channel ;
  {channel}

let publish ?ephemeral topic value =
  ignore ephemeral ;
  ignore topic ;
  ignore value

let publish_keyed ?ephemeral topic ~key value =
  ignore ephemeral ;
  ignore topic ;
  ignore key ;
  ignore value

let subscribe ?live_only topic callback =
  ignore live_only ;
  ignore topic ;
  ignore callback ;
  0

let subscribe_keyed ?live_only topic callback =
  ignore live_only ;
  ignore topic ;
  ignore callback ;
  0

let request ~cmd ~reply ~key ?(timeout = 5.0) value =
  ignore cmd ;
  ignore reply ;
  ignore key ;
  ignore timeout ;
  value

module MessageBus = struct
  let publish channel payload =
    ignore channel ;
    ignore payload ;
    0

  let subscribe pattern callback =
    ignore pattern ;
    ignore callback ;
    0

  let once channel callback =
    ignore channel ;
    ignore callback ;
    0
end
