(* Client layer — page handler calls the TaskManager service *)

let ctx_w = Well.{session_id= "s"; user_id= None}

let tasks_handler req =
  ignore req ;
  let req = {Task_manager.AddReq.title= Shared.render_title "new"} in
  let _task = Task_manager.add ~ctx:ctx_w ~title:req.title in
  ignore _task ;
  0
