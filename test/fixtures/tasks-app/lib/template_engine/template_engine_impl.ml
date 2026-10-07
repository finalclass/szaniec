(* TemplateEngine implementation — an Engine service *)

module Impl : Template_engine.IMPL = struct
  let expand _ctx text = "{" ^ text ^ "}"
end

let spec = Template_engine.make_spec (module Impl)
