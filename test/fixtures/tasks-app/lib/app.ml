(* Composition root — registers services and routes *)

let run () =
  Well.Service.register Task_access_impl.spec ;
  Well.Service.register Task_manager_impl.spec ;
  Well.Service.register Formatting_engine_impl.spec ;
  Well.Service.register Template_engine_impl.spec ;
  Well.Service.register Notification_manager_impl.spec ;
  Well.Service.register Web_client.Audit_client_impl.spec ;
  Well.Service.expose "TaskManager" ;
  Well.get "/tasks" Web_client.Tasks_page.tasks_handler ;
  Well.get "/help" Web_client.Help_page.help_handler ;
  Well.run ()
