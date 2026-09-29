(* Composition root — registers services and routes *)

let run () =
  Well.Service.register Services.Task_access_impl.spec ;
  Well.Service.register Services.Task_manager_impl.spec ;
  Well.Service.register Services.Formatting_engine_impl.spec ;
  Well.Service.register Services.Template_engine_impl.spec ;
  Well.Service.register Services.Notification_manager_impl.spec ;
  Well.Service.expose "TaskManager" ;
  Well.get "/tasks" Pages.Tasks_page.tasks_handler ;
  Well.get "/help" Pages.Help_page.help_handler ;
  Well.run ()
