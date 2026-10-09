module Browser = App_browser.Nested
module Messages = Browser.Common

let decode_many values = List.map Messages.Message.from_drut values
let decode_payload text = Messages.Payload.from_drut text

let show () =
  let message = App_contract.Common.Message.make ~value:"client" in
  ignore (App_contract.Task_manager.read ~ctx:() message);
  let message = Messages.Message.make ~value:"browser" in
  let value = Messages.Message.Storage.to_storage_value message in
  let value = Messages.Message.Storage.wire_of_storage value in
  let value = Messages.Message.Storage.storage_of_wire value in
  let message = Messages.Message.Storage.from_storage_value value in
  Browser.Task_manager.Proxy.read message ~on_done:ignore
