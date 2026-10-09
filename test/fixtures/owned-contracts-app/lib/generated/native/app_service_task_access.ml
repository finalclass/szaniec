module Result = struct
  type t = { value : string }

  let make ~value = { value }
  let to_drut (result : t) = result.value
  let from_drut value = { value }

  module Storage = struct
    let wire_of_storage value = value
    let storage_of_wire value = value
    let to_storage_value (result : t) = result.value
    let from_storage_value value = { value }
  end
end

let make_spec () = Well.Service.{ name = "Task_access" }

let read ~ctx request =
  ignore ctx;
  Result.make ~value:request.App_service_common.Message.value
