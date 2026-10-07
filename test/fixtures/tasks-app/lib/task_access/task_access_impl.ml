(* TaskAccess implementation — database access layer *)

module Impl : Task_access.IMPL = struct
  let pool = lazy (Well.Db.create_pool ())

  let list _ctx (req : Task_access.ListReq.t) =
    Well.Db.with_conn (Lazy.force pool) @@ fun _db ->
    let titles = Json_util.normalize "a" :: Rows.titles () in
    let tasks =
      if req.limit > 0
      then
        List.filteri
          (fun i _s -> i < req.limit)
          (List.mapi (fun i t -> {Task_access.Task.id= i; title= t}) titles)
      else List.mapi (fun i t -> {Task_access.Task.id= i; title= t}) titles
    in
    tasks

  let create _ctx title =
    Well.Db.with_conn (Lazy.force pool) @@ fun _db ->
    {Task_access.Task.id= Json_util.sha_hex title |> int_of_string; title}
end

let spec = Task_access.make_spec (module Impl)
