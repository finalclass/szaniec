let answer () =
  let inner () = Coverage_app_core.Core.base + 2 in
  inner ()

let nested () = (fun s -> s) (Coverage_app_core.Core.greet "n")

let unused_api () = 0

let marker = [%coverage_mark]
