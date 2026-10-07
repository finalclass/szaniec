let base = 40

let unused () = base + 2

let greet who =
  let suffix () = "!" in
  "hello " ^ who ^ suffix ()
