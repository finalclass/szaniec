(* TaskManager implementation — business logic layer *)

module Impl : Task_manager.IMPL = struct
  let list ctx (req : Task_access.ListReq.t) =
    (Task_manager.list ~ctx ~limit:req.limit).tasks

  let add ctx (req : Task_manager.AddReq.t) =
    Task_access.create ~ctx ~title:req.title
end

let spec = Task_manager.make_spec (module Impl)
