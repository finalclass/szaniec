(* Audit_client implementation. The source file sits beside the
   composition root, so its path stem and Audit_client.make_spec name
   the same family. It is not under web_client: that directory is the
   Web_client family. *)

module Impl : Audit_client.IMPL = struct
  let record _ctx _text = true
end

let spec = Audit_client.make_spec (module Impl)
