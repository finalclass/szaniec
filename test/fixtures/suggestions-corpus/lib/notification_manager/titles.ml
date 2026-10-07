let normalize_title title =
  let trimmed = String.trim title in
  let lower = String.lowercase_ascii trimmed in
  let buf = Buffer.create (String.length lower) in
  Buffer.add_string buf lower ;
  Buffer.contents buf
