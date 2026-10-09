(* CLI-owned lazy JSON preserves the existing Yojson pretty layout without
   materializing every flow and execution-context JSON node at once. *)
type t =
  [ `String of string
  | `Int of int
  | `Assoc of (string * t) list
  | `List of unit -> t list ]

let text = Format.pp_print_string

let quoted value = Yojson.Safe.to_string (`String value)

let atom = function
  | `String _
   |`Int _
   |`Assoc [] ->
      true
  | `List values -> values () = []
  | `Assoc _ -> false

let separated printer out values =
  List.iteri
    (fun i value ->
      if i > 0
      then (
        text out "," ;
        Format.pp_print_break out 1 0 ) ;
      printer out value )
    values

let rec node ~inside out = function
  | `String value -> text out (quoted value)
  | `Int value -> Format.pp_print_int out value
  | `Assoc [] -> text out "{}"
  | `Assoc fields ->
      if not inside then Format.pp_open_hvbox out 2 ;
      text out "{" ;
      Format.pp_print_break out 1 0 ;
      separated field out fields ;
      Format.pp_print_break out 1 (-2) ;
      text out "}" ;
      if not inside then Format.pp_close_box out ()
  | `List values -> (
    match values () with
    | [] -> text out "[]"
    | values ->
        if not inside then Format.pp_open_hvbox out 2 ;
        text out "[" ;
        Format.pp_print_break out 1 0 ;
        if List.for_all atom values
        then Format.pp_open_hovbox out 0
        else Format.pp_open_hvbox out 0 ;
        separated (node ~inside:false) out values ;
        Format.pp_close_box out () ;
        Format.pp_print_break out 1 (-2) ;
        text out "]" ;
        if not inside then Format.pp_close_box out () )

and field out (name, value) =
  Format.pp_open_hvbox out 2 ;
  text out (quoted name ^ ": ") ;
  node ~inside:true out value ;
  Format.pp_close_box out ()

let to_channel channel value =
  let out = Format.formatter_of_out_channel channel in
  Format.pp_open_hvbox out 2 ;
  node ~inside:true out value ;
  Format.pp_close_box out () ;
  Format.pp_print_flush out ()
