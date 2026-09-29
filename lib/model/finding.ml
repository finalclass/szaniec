(* Findings and the final report. Mirrors docs/contracts/inspection-contract.md. *)

type severity =
  | Violation
  | GapFinding

type location =
  { loc_path: string
  ; loc_line: int
  ; loc_col: int }

type t =
  { rule: string
  ; severity: severity
  ; message: string
  ; participants: string list
  ; locations: location list
  ; evidence_path: string list }

let sort_key (f : t) =
  ( f.rule
  , String.concat "," f.participants
  , ( match f.locations with
    | l :: _ -> (l.loc_path, l.loc_line, l.loc_col)
    | [] -> ("", 0, 0) )
  , String.concat ">" f.evidence_path
  , String.concat
      "|"
      (List.map
         (fun l -> l.loc_path ^ ":" ^ string_of_int l.loc_line)
         f.locations ) )

let compare (a : t) (b : t) = compare (sort_key a) (sort_key b)

let dedupe (fs : t list) : t list =
  let rec go seen = function
    | [] -> List.rev seen
    | f :: rest ->
        if List.exists (fun g -> compare f g = 0) seen
        then go seen rest
        else go (f :: seen) rest
  in
  go [] fs

type status =
  | Ok
  | Violations
  | Incomplete

type policy_identity =
  { policy_name: string
  ; policy_digest: string
  ; approved: bool
  ; approved_digest: string option }

type inputs =
  { policy: policy_identity
  ; profile: string
  ; program_roots: string list
  ; snapshot_digest: string
  ; compiler: string
  ; exclusions: string list }

type summary =
  { violations: int
  ; gaps: int
  ; units: int
  ; calls: int
  ; type_refs: int }

type report =
  { status: status
  ; inputs: inputs
  ; findings: t list
  ; summary: summary }
