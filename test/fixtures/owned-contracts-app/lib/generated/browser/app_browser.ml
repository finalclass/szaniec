module Nested = struct
  module Common : module type of App_service_common = App_service_common

  module Task_manager : module type of App_service_task_manager =
    App_service_task_manager
end
