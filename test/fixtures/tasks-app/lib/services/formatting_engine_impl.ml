(* FormattingEngine implementation — an Engine service *)

module Impl : Formatting_engine.IMPL = struct
  let render _ctx text = String.uppercase_ascii text
end

let spec = Formatting_engine.make_spec (module Impl)
