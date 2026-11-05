(* Cyrograf contract files: the approved-architecture projection of
   services. A .cyrograf file that declares rpc methods is a service named
   after its file stem. Roles are policy and are decided by
   ConformanceEngine, not here. *)

type method_decl =
  { m_name: string
  ; m_request: string (* request type name from the rpc line *)
  ; m_response: string }

(* Parse "rpc name(Req) -> Res" from a .cyrograf file. Anything that is
   not an rpc line is not read by this projection. *)
let parse_rpcs (content : string) : method_decl list =
  let methods = ref [] in
  String.split_on_char '\n' content
  |> List.iter (fun line ->
      let line = String.trim line in
      match String.index_opt line ' ' with
      | Some i when String.sub line 0 i = "rpc" -> (
          let rest =
            String.trim (String.sub line (i + 1) (String.length line - i - 1))
          in
          match (String.index_opt rest '(', String.index_opt rest ')') with
          | Some open_p, Some close_p when open_p > 0 && close_p > open_p -> (
              let name = String.sub rest 0 open_p in
              let req =
                String.trim
                  (String.sub rest (open_p + 1) (close_p - open_p - 1))
              in
              let after =
                String.sub rest (close_p + 1) (String.length rest - close_p - 1)
              in
              match String.index_opt after '-' with
              | Some arrow
                when arrow + 2 <= String.length after
                     && String.sub after arrow 2 = "->" ->
                  let res =
                    String.trim
                      (String.sub
                         after
                         (arrow + 2)
                         (String.length after - arrow - 2) )
                  in
                  let valid_name =
                    String.length name > 0
                    &&
                    match name.[0] with
                    | 'a' .. 'z'
                     |'_' ->
                        true
                    | _ -> false
                  in
                  if valid_name && req <> "" && res <> ""
                  then
                    methods :=
                      {m_name= name; m_request= req; m_response= res}
                      :: !methods
              | _ -> () )
          | _ -> () )
      | _ -> () ) ;
  List.sort (fun a b -> String.compare a.m_name b.m_name) !methods
