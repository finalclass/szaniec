let read () =
  let result = App_contract.Task_access.Result.make ~value:"ready" in
  let value = App_contract.Task_access.Result.Storage.to_storage_value result in
  let value = App_contract.Task_access.Result.Storage.wire_of_storage value in
  let value = App_contract.Task_access.Result.Storage.storage_of_wire value in
  let result =
    App_contract.Task_access.Result.Storage.from_storage_value value
  in
  App_contract.Task_access.Result.to_drut result

let spec = App_contract.Task_access.make_spec ()
