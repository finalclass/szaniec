module Message = struct
  type t = { value : string }

  let make ~value = { value }
  let to_drut (message : t) = message.value
  let from_drut value = { value }
end
