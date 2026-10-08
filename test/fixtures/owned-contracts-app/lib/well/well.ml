type rpc_ctx = unit

module Service = struct
  type spec = { name : string }

  let register (_ : spec) = ()
end
