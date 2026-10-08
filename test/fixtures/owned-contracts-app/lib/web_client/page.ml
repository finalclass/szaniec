module Browser = App_browser.Nested
module Messages = Browser.Common

let show () =
  let message = App_contract.Common.Message.make ~value:"client" in
  ignore (App_contract.Task_manager.read ~ctx:() message);
  let message = Messages.Message.make ~value:"browser" in
  Browser.Task_manager.Proxy.read message ~on_done:ignore
