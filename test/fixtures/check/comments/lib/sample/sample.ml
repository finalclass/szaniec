let url = "http://example.com (* not a comment *)"
(* block *)
let quoted = {|(* not a comment *)|}
let extension = {%sql|(* not a comment *)|}
(** documentation *)
let quote = '"'
let nested = 1 (* outer (* inner *) "*)" *)
let prime' = 'x'
