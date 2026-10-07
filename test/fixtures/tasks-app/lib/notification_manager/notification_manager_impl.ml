(* NotificationManager implementation — a Manager service *)

module Impl : Notification_manager.IMPL = struct
  let publish _ctx _text = true
end

let spec = Notification_manager.make_spec (module Impl)
