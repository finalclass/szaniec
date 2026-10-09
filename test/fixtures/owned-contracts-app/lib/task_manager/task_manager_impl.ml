module Contract = App_contract.Common

let read () =
  let value = Task_access_lib.Api.Public.read () in
  let message = Contract.Message.make ~value in
  let message = Contract.Message.from_data (Contract.Message.to_data message) in
  let value = Contract.Message.Storage.to_storage_value message in
  let message = Contract.Message.Storage.from_storage_value value in
  Contract.Message.to_drut message

let spec = App_contract.Task_manager.make_spec ()
let payload value = Contract.Payload.to_drut (Contract.Payload.make ~value ())
