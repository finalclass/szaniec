(* Private helper of the Web_client family, consumed by both pages.
   Format.Titles is a nested directory of the same family. *)

let render_title (t : string) : string = Format.Titles.decorate t
