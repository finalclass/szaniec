(lang dune 3.17)

(name szaniec)

(implicit_transitive_deps false)

(package
 (name szaniec)
 (allow_empty)
 (depends
  (ocaml (and (>= 5.4) (< 5.5)))
  digestif
  yojson
  (ocamlformat (= 0.29.0))))
