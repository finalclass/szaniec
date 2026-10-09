type value = [ `String of string | `List of value list ]

let enc_string value = Ok (`String value)

let enc_list encode items =
  let rec loop acc = function
    | [] -> Ok (`List (List.rev acc))
    | value :: rest -> (
        match encode value with
        | Ok wire -> loop (wire :: acc) rest
        | Error _ as error -> error)
  in
  loop [] items

let dec_string = function
  | `String value -> Ok value
  | _ -> Error "expected string"

let dec_struct size = function
  | `List values when List.length values = size -> Ok (Array.of_list values)
  | _ -> Error "expected struct"

let field _ result = result
let index _ result = result
let to_string = function `List [ `String value ] -> value | _ -> ""
let of_string value = Ok (`List [ `String value ])

module Syntax = struct
  let ( let* ) result f = Result.bind result f
  let ( let+ ) result f = Result.map f result
end
