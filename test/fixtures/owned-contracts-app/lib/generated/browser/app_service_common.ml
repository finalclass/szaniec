module Message = struct
  type t = { value : string }

  let make ~value = { value }
  let to_drut (message : t) = message.value
  let from_drut value = { value }

  module Storage = struct
    let wire_of_storage value = value
    let storage_of_wire value = value
    let to_storage_value (message : t) = message.value
    let from_storage_value value = { value }
  end
end

module Cyrograf = struct
  module Error = struct
    type t = string
  end
end

module Payload = struct
  type t = { value : string }

  let make ~value () = { value }

  let encode_value (v : t) : (Drut_runtime.value, Cyrograf.Error.t) result =
    let open! Drut_runtime.Syntax in
    let* f0 = Drut_runtime.field "value" (Drut_runtime.enc_string v.value) in
    Ok (`List [ f0 ])

  let decode_value (wire : Drut_runtime.value) : (t, Cyrograf.Error.t) result =
    let open! Drut_runtime.Syntax in
    let* arr = Drut_runtime.dec_struct 1 wire in
    let* value = Drut_runtime.field "value" (Drut_runtime.dec_string arr.(0)) in
    Ok { value }

  let to_drut (v : t) : (string, Cyrograf.Error.t) result =
    match encode_value v with
    | Ok wire -> Ok (Drut_runtime.to_string wire)
    | Error _ as error -> error

  let from_drut (text : string) : (t, Cyrograf.Error.t) result =
    match Drut_runtime.of_string text with
    | Ok wire -> decode_value wire
    | Error _ as error -> error
end
