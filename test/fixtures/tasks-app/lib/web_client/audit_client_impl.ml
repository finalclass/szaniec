(* AuditClient implementation. The module lives under web_client so a
   name-suffix guess would call it a client page; registration via
   Audit_client.make_spec is what binds it to the Audit_client service. *)

module Impl : Audit_client.IMPL = struct
  let record _ctx _text = true
end

let spec = Audit_client.make_spec (module Impl)
