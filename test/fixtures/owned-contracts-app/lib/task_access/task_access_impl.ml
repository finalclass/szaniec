let read () =
  let result = App_contract.Task_access.Result.make ~value:"ready" in
  App_contract.Task_access.Result.to_drut result

let spec = App_contract.Task_access.make_spec ()
