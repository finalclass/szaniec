module Contract = App_contract.Common

let read () =
  let value = Task_access_lib.Api.Public.read () in
  let message = Contract.Message.make ~value in
  Contract.Message.to_drut message

let spec = App_contract.Task_manager.make_spec ()
