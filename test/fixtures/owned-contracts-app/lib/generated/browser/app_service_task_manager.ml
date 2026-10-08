module Proxy = struct
  let read request ~on_done =
    on_done
      (App_service_common.Message.from_drut
         (App_service_common.Message.to_drut request))
end
