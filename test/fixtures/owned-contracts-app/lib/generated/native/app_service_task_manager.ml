let make_spec () = Well.Service.{ name = "Task_manager" }

let read ~ctx request =
  ignore ctx;
  App_service_common.Message.from_drut
    (App_service_common.Message.to_drut request)
