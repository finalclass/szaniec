let choose_channel kind urgent archived draft pinned muted =
  if kind = "email" && urgent && not archived
  then "now"
  else if kind = "email" && draft
  then "draft"
  else if kind = "pdf" && pinned
  then "pdf"
  else if muted || archived
  then "quiet"
  else if kind = "email"
  then "later"
  else "skip"
