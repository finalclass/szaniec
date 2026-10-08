(lang dune 3.17)

(name szaniec)

(package
 (name szaniec)
 (allow_empty)
 (depends
  (ocaml (and (>= 5.4) (< 5.5)))
  yojson
  digestif
  ppxlib
  bisect_ppx_ng
  ocamlformat))
