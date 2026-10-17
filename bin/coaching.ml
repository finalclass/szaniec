type guide =
  { id: string
  ; intent: string
  ; steps: string list
  ; avoid: string list
  ; before: string
  ; after: string
  ; verification: string list }

let catalog = "szaniec-coaching/1"

let guide ~verification id intent steps avoid before after =
  {id; intent; steps; avoid= [avoid]; before; after; verification}

let inspection =
  guide
    ~verification:
      [ "Run the affected behavior tests and szaniec check --rebuild; inspect \
         the original call path and retain every remaining gap." ]

let suggestion =
  guide
    ~verification:
      [ "Run affected behavior tests and a full szaniec check --rebuild after \
         edits; review suggestions again when available. A lower metric or \
         recorded apply decision is not proof of a correct refactor." ]

let evidence =
  guide
    ~verification:
      [ "Acquire the missing evidence and rerun the full check. If evidence is \
         still unavailable, retain the gap and incomplete status." ]

let inspection_guides =
  [ ( ["ID-CLIENT-ACCESS"; "ID-CLIENT-ENGINE"]
    , inspection
        "client-business-entry"
        "Keep presentation separate from business workflow and resource access."
        [ "Trace the reported call and helper path to the Client entry point."
        ; "Route the use case through the appropriate existing Manager \
           contract; keep workflow and resource access behind their approved \
           boundaries." ]
        "A Client-local wrapper around the same forbidden call, a renamed \
         service, or a new pass-through Manager only to silence the rule."
        "Client -> helper -> Access"
        "Client -> existing Manager use case -> Access" )
  ; ( ["ID-ENGINE-ENGINE"]
    , inspection
        "engine-isolation"
        "Keep independent business activities isolated."
        [ "Identify the activity owned by each Engine."
        ; "Let the owning Manager compose the activities through their public \
           contracts, preserving required inputs and ordering." ]
        "Hiding Engine-to-Engine calls in a helper or Utility, or moving \
         business rules into the Manager just to erase an edge."
        "Engine A -> Engine B"
        "Manager -> Engine A; Manager -> Engine B" )
  ; ( ["ID-ACCESS-ACCESS"]
    , inspection
        "atomic-access"
        "Expose an atomic resource operation from its owning Access boundary."
        [ "Determine the atomic business verb and the resources it must access."
        ; "Keep its resource implementation inside the owning Access; put \
           composition of separate business operations in the appropriate \
           Manager." ]
        "Extracting resource implementation into a shared helper consumed by \
         several Access services."
        "Access A -> Access B to complete one atomic verb"
        "Owning Access implements the complete atomic verb" )
  ; ( ["ID-ACCESS-OUTBOUND"]
    , inspection
        "access-direction"
        "Keep workflow and business-rule decisions above resource access."
        [ "Identify the workflow or rule invoked by the Access service."
        ; "Move that decision to its existing Manager or Engine, which invokes \
           the Access contract." ]
        "A callback or alias that retains the Access-to-business-layer \
         dependency."
        "Access -> Manager or Engine"
        "Manager or Engine -> Access" )
  ; ( ["ID-MANAGER-CLIENT"; "ID-ENGINE-CLIENT"; "ID-ACCESS-CLIENT"]
    , inspection
        "client-boundary"
        "Keep presentation inside the Client boundary."
        [ "Identify the data or outcome needed by the Client."
        ; "Return it through the existing public contract and let the Client \
           perform presentation; review a genuine contract change separately."
        ]
        "Importing Client implementation through an alias or callback to \
         conceal the upward call."
        "Business service -> Client.render"
        "Client renders the result of its Manager call" )
  ; ( ["ID-MANAGER-MANAGER"]
    , inspection
        "manager-delegation"
        "Preserve use-case boundaries and command semantics."
        [ "Determine whether the caller requires a synchronous result."
        ; "Use approved queued delegation when asynchronous behavior is valid; \
           otherwise review workflow ownership rather than mechanically \
           changing the transport." ]
        "Replacing a synchronous call with a queue while losing a required \
         result, ordering, or failure behavior."
        "Manager A synchronously calls Manager B"
        "Manager A queues one command to Manager B when the use case permits it"
    )
  ; ( ["UC-CLIENT-MULTI-MANAGER"]
    , inspection
        "single-use-case"
        "Keep the use-case sequence in its owning Manager."
        [ "Inspect the reported executable path; keep mutually exclusive \
           branches and independent handlers distinct."
        ; "Have the Client invoke one existing Manager use case that owns the \
           required sequence." ]
        "Moving the same multi-Manager orchestration into Client-local helpers \
         or treating alternative paths as sequential."
        "One Client path invokes Manager A and Manager B"
        "Client invokes its owning Manager use case" )
  ; ( ["Q-TARGET-ROLE"]
    , inspection
        "queue-target"
        "Deliver a queued command to its owning Manager."
        [ "Inspect the topic and its resolved subscriber."
        ; "Let the owning Manager receive the command and invoke permitted \
           Engine or Access contracts." ]
        "Renaming an Engine as a Manager or substituting event publication for \
         a command without preserving semantics."
        "Queued command -> Engine"
        "Queued command -> Manager -> Engine" )
  ; ( ["Q-MULTI-MANAGER"]
    , inspection
        "queue-fanout"
        "Give a command one resolved Manager target."
        [ "Inspect every subscriber to the reported command topic."
        ; "Separate commands by owner; if the message is actually an event, \
           review its semantics and use approved publication/subscription." ]
        "Dropping required consumers arbitrarily or relabeling fan-out as a \
         command."
        "One command topic targets Manager A and Manager B"
        "A command targets its one owning Manager" )
  ; ( ["EVT-PUBLISH-ROLE"]
    , inspection
        "event-publication"
        "Publish the business outcome from its owning Manager."
        [ "Trace the actual publishing operation and its owner."
        ; "Have the owning Manager publish after the relevant business \
           activity completes, preserving the event payload and timing." ]
        "Changing only the topic name or hiding publication behind a Utility."
        "Engine publishes a business event"
        "Manager invokes the Engine and publishes the outcome" )
  ; ( ["EVT-SUBSCRIBE-ROLE"]
    , inspection
        "event-subscription"
        "Receive events in an approved Client or Manager boundary."
        [ "Inspect the registered callback and the responsibility it performs."
        ; "Let a Client or Manager own receipt and delegate work through \
           permitted public contracts." ]
        "Moving only registration while retaining a forbidden subscriber's \
         executable responsibility."
        "Access subscribes and performs work"
        "Manager subscribes and invokes the Access contract" )
  ; ( ["IMPL-ACCESS-CROSS-SERVICE"]
    , inspection
        "public-contract"
        "Use another service through its approved public surface."
        [ "Trace the reported private implementation reference, including \
           aliases and callbacks."
        ; "Use the appropriate approved public contract or keep private work \
           inside its owning service; review a genuine missing facet \
           separately." ]
        "Import indirection or whitelisting business implementation to \
         disguise cross-service reuse."
        "Service A -> Service B private helper"
        "Service A -> Service B approved contract" )
  ; ( ["SHARED-UNAPPROVED"]
    , inspection
        "owned-sharing"
        "Establish ownership before sharing executable implementation."
        [ "Compare the consumers' responsibilities and reasons for change."
        ; "Keep business implementation within its owning families; obtain \
           separate architecture review for genuinely cross-cutting \
           infrastructure." ]
        "Creating Common, Shared, or Utils, or adding blanket approval merely \
         because bodies look alike."
        "Several services execute an unowned Shared helper"
        "Each family owns its private behavior, or explicitly reviewed \
         infrastructure owns the shared mechanism" )
  ; ( ["RESOURCE-BOUNDARY"]
    , inspection
        "resource-access"
        "Encapsulate resource operations behind authorized contracts."
        [ "Identify the protected resource API and actual performing boundary."
        ; "Route the operation through an authorized Access contract, \
           preserving transactions and failure behavior." ]
        "Approving the SQL or framework library as a substitute for resource \
         permission."
        "Client directly queries the database"
        "Client -> Manager -> Access business verb -> database" )
  ; ( ["POLICY-UNCLASSIFIED"]
    , inspection
        "implementation-ownership"
        "Give in-scope implementation a deliberate owner."
        [ "Identify the responsibility of the reported source module."
        ; "Place private code inside its correct existing family or obtain \
           review for a real boundary/infrastructure declaration." ]
        "Removing the source from analysis roots, treating one caller as \
         ownership, or adding blanket sharing approval."
        "Unowned executable helper outside all families"
        "Private helper inside its owning family's source tree" )
  ; ( ["SPEC-UNDECLARED-METHOD"]
    , inspection
        "declared-method"
        "Keep implementation calls consistent with the declared contract."
        [ "Compare the resolved member with the service's declared RPC surface."
        ; "Use the intended declared operation or request a genuine contract \
           change before implementing new behavior." ]
        "Adding an RPC declaration solely to make the checker pass."
        "Caller invokes a private undeclared member"
        "Caller invokes the intended declared RPC" )
  ; ( ["SPEC-UNREGISTERED-SERVICE"]
    , inspection
        "service-registration"
        "Mount the declared service through the supported composition \
         mechanics."
        [ "Inspect the implementation binding and composition-root registration."
        ; "Bind the intended implementation to its contract and mount that \
           bound service." ]
        "Deleting the contract to conceal missing registration."
        "RPC contract exists without a mounted implementation"
        "Composition root registers the implementation bound to that contract"
    )
  ; ( [ "GAP-BUILD"
      ; "GAP-UNOBSERVED-SOURCE"
      ; "GAP-STALE-ARTIFACT"
      ; "GAP-MISSING-INPUT"
      ; "GAP-UNVERIFIABLE-TRANSFORMATION"
      ; "GAP-INCOMPLETE-ARTIFACT"
      ; "GAP-ARTIFACT-READ" ]
    , evidence
        "fresh-artifacts"
        "Restore current, complete compiler evidence before judging \
         conformance."
        [ "Read the named build/input failure and fix its concrete cause."
        ; "Run szaniec check --rebuild using the project's configured build; \
           verify all in-scope sources and transformation inputs are \
           represented." ]
        "Touching files, forging transformation receipts, reusing stale \
         artifacts, or excluding failing sources to get a pass."
        "Missing, stale, unreadable, or partial typed artifacts"
        "Complete typed artifacts tied to current source and build inputs" )
  ; ( ["GAP-SOURCE-MAPPING"]
    , evidence
        "source-mapping"
        "Tie executable evidence to its authored source locations."
        [ "Inspect the named transformation and missing authored mapping."
        ; "Restore the supported source mapping and rebuild the affected \
           artifacts." ]
        "Guessing authored line numbers or excluding the transformed source."
        "Executable location without authored mapping"
        "Supported transformation retains authored location evidence" )
  ; ( [ "GAP-UNSUPPORTED-COMPILER"
      ; "GAP-PROFILE-UNSUPPORTED"
      ; "GAP-UNSUPPORTED-CONSTRUCT"
      ; "GAP-UNRESOLVED-CALL"
      ; "GAP-CALLBACK-SEMANTICS"
      ; "GAP-RETURNED-CLOSURE"
      ; "GAP-AMBIGUOUS-PATH"
      ; "GAP-UNRESOLVED-TARGET"
      ; "GAP-UNMEASURABLE" ]
    , evidence
        "supported-evidence"
        "Resolve the precise analysis limit without inventing program behavior."
        [ "Inspect the reported compiler/profile, construct, target, or \
           execution-path limitation."
        ; "Acquire supported evidence or make a behavior-preserving change \
           that the adapter can resolve; retain an explicit limitation if \
           neither is possible." ]
        "Guessing targets or execution order, treating missing evidence as \
         success, or suppressing the gap."
        "Unknown target or execution semantics"
        "Resolved supported evidence, or an explicitly retained gap" )
  ; ( ["GAP-POLICY-NOT-APPROVED"]
    , evidence
        "approved-policy"
        "Check against the deliberately selected approved architecture."
        [ "Compare the policy name and digest with the intended approved \
           version."
        ; "Restore that selected policy, or obtain architecture review for a \
           genuine change through the project's approval process." ]
        "Automatically approving the current policy on every check or \
         weakening it to match a violation."
        "Implementation patch also changes its own permitted policy"
        "Check uses the reviewed approved policy identity" )
  ; ( ["GAP-AMBIGUOUS-OWNERSHIP"; "GAP-LOCAL-SERVICE"; "GAP-PUBLIC-CONTRACT"]
    , evidence
        "ownership-evidence"
        "Resolve ownership and binding evidence before choosing a repair."
        [ "Inspect conflicting or missing source, contract, and registration \
           evidence."
        ; "Correct the binding or obtain deliberate review for a declaration \
           change, then rebuild." ]
        "Choosing whichever owner permits the call or treating an api \
         directory name as approval."
        "Conflicting family or public-contract bindings"
        "One reviewed declaration supported by fresh compiler evidence" )
  ; ( ["GAP-SUGGESTION-NO-SOURCE"]
    , evidence
        "available-source"
        "Restore the source context needed for a meaningful suggestion review."
        [ "Locate the catalog definition whose source slice is unavailable."
        ; "Restore the source tied to its current compiler artifact and rerun \
           suggestions with fresh catalog evidence." ]
        "Synthesizing a missing body or interpreting skipped review as no \
         issue."
        "Catalog definition without its source body"
        "Fresh catalog definition with the matching authored source slice" ) ]

let for_rule rule =
  List.find_map
    (fun (rules, guide) -> if List.mem rule rules then Some guide else None)
    inspection_guides

let suggestion_guides =
  [ ( "name-quality"
    , suggestion
        "meaningful-name"
        "Name the observed intent rather than the implementation accident."
        [ "Read the definition, parameters, and supplied call sites."
        ; "Choose a name describing the actual behavior and update resolved \
           uses consistently." ]
        "Longer meaningless names or domain intent unsupported by the \
         available context."
        "process title (when its body normalizes a title)"
        "normalize_title title" )
  ; ( "responsibility-mix"
    , suggestion
        "cohesive-responsibility"
        "Give each operation a coherent responsibility inside its owner."
        [ "Describe what the function does in one sentence; identify unrelated \
           concerns and their reasons for change."
        ; "Extract meaningful private operations inside the owning service and \
           preserve the existing public contract." ]
        "Cutting at an arbitrary line, naming a second half function2, or \
         moving business implementation across service boundaries."
        "One function formats a result and performs unrelated storage work"
        "Named private operations separate formatting and storage, composed by \
         their existing owner" )
  ; ( "complicated-construct"
    , suggestion
        "readable-control-flow"
        "Make control flow easier to understand while preserving behavior."
        [ "Explain the function's intent in one sentence and inspect redundant \
           decisions, nesting, and distinct cases."
        ; "Simplify redundant branching or extract a meaningful operation with \
           explicit inputs and output inside the same owner; compare the whole \
           operation and its helpers." ]
        "Moving identical branches into function2, compressing syntax, or \
         presenting a lower local complexity score as proof of improvement."
        "A nested decision tree is cut in half to satisfy a metric"
        "The operation expresses its cases clearly and delegates a named \
         coherent activity" )
  ; ( "vocabulary-consistency"
    , suggestion
        "consistent-vocabulary"
        "Use consistent names for the same concept in the supplied context."
        [ "Compare the local definitions and their actual meanings."
        ; "Align synonyms for the same concept and update uses; retain names \
           for genuinely different concepts." ]
        "Imposing global vocabulary without evidence from the relevant context."
        "customer and client mean the same local concept"
        "One consistent local term for that concept" )
  ; ( "predicate-clarity"
    , suggestion
        "clear-predicate"
        "Make boolean conditions and their branches easy to read."
        [ "Write the predicate's truth conditions and inspect each supplied use."
        ; "Use a clear boolean name and align branches while preserving those \
           truth conditions." ]
        "Renaming a negative predicate without adjusting its logic and callers."
        "if not (not_ready task) then execute task"
        "if ready task then execute task, with the same truth conditions" )
  ; ( "unexpected-effects"
    , suggestion
        "explicit-effects"
        "Make side effects visible in the operation's meaning."
        [ "Identify the observed write, send, or other effect in the supplied \
           body."
        ; "Expose that effect in the appropriate name/contract or separate it \
           within the owning boundary." ]
        "A harmless-looking wrapper that retains the hidden effect."
        "format_report also writes the report"
        "format_report returns text; save_report performs the explicit write" )
  ; ( "mode-flags"
    , suggestion
        "coherent-operations"
        "Keep operations coherent while preserving legitimate options."
        [ "Identify which flags select unrelated operations and which merely \
           configure one operation."
        ; "Separate unrelated behavior into explicit operations with their \
           required inputs." ]
        "Replacing flags with an opaque options bag that preserves the same \
         unrelated modes."
        "handle ~print:true ~save:false"
        "Explicit print_report and save_report operations where those are \
         distinct responsibilities" )
  ; ( "comment-mismatch"
    , suggestion
        "accurate-comment"
        "Keep explanations consistent with approved behavior."
        [ "Compare the comment, actual body, and authoritative behavior \
           specification."
        ; "Remove a redundant comment or correct a misleading explanation; fix \
           behavior separately if it violates the specification." ]
        "Changing correct behavior merely to agree with a stale comment."
        "Comment claims validation while the function only formats"
        "A necessary explanation matches the actual approved behavior" )
  ; ( "unnecessary-indirection"
    , suggestion
        "useful-abstraction"
        "Keep abstractions that express a boundary, adaptation, or useful \
         intent."
        [ "Inspect callers and the forwarding operation's ownership and \
           contract role."
        ; "Remove it only if no approved boundary, adaptation, or meaningful \
           name is lost." ]
        "Inlining a public service contract or erasing an abstraction just to \
         reduce call count."
        "Private helper only forwards unchanged arguments without adding \
         meaning"
        "Caller uses the same approved operation directly" )
  ; ( "idiomatic-alternative"
    , suggestion
        "suitable-idiom"
        "Choose an available idiom whose semantics make the code clearer."
        [ "Check the supplied API's types, ordering, effects, and failure \
           behavior."
        ; "Replace the construct only when that API fits and improves clarity."
        ]
        "Inventing an API or replacing a clear body with a clever fold."
        "Manual construct matches the supplied API's semantics"
        "Use that available API with equivalent behavior when clearer" ) ]

let reuse_guide = function
  | Some "same-service" ->
      suggestion
        "reuse-within-service"
        "Reuse a coherent private operation within its existing service."
        [ "Compare the bodies, callers, effects, and failure behavior; \
           semantic similarity alone is not equivalence."
        ; "When behavior genuinely agrees, reuse one meaningful definition \
           inside that service." ]
        "Merging different behaviors through mode flags or exporting the \
         private helper across services."
        "Two equivalent private definitions inside one service"
        "One private operation reused by that service's callers"
  | Some "distinct-services" ->
      suggestion
        "reuse-across-services"
        "Respect independently owned behavior even when source bodies match."
        [ "Compare each service's responsibility and reasons for change."
        ; "Keep separate implementations unless an existing approved public \
           contract genuinely owns the behavior; obtain review for a real \
           architectural change." ]
        "A shared business library created just to remove duplication, or an \
         identical body treated as permission to cross boundaries."
        "Matching helper bodies in Service A and Service B"
        "Separate owned helpers, or reuse through a genuinely appropriate \
         approved public contract"
  | _ ->
      suggestion
        "reuse-needs-ownership"
        "Resolve ownership before deciding whether reuse is appropriate."
        [ "Inspect the ambiguous, unclassified, or missing ownership evidence \
           for both definitions."
        ; "Establish their approved owners before choosing private reuse or \
           retaining separate implementations." ]
        "Inferring ownership from one caller or treating unknown ownership as \
         permission to share."
        "Similar bodies with unresolved ownership"
        "Ownership is resolved before a reuse decision"

let for_suggestion ~criterion ~ownership_relation =
  match criterion with
  | "exact-duplicate"
   |"semantic-reuse" ->
      Some (reuse_guide ownership_relation)
  | _ -> List.assoc_opt criterion suggestion_guides

let to_json = function
  | None -> `Null
  | Some g ->
      let strings xs = `List (List.map (fun s -> `String s) xs) in
      `Assoc
        [ ("catalog", `String catalog)
        ; ("id", `String g.id)
        ; ("intent", `String g.intent)
        ; ("steps", strings g.steps)
        ; ("avoid", strings g.avoid)
        ; ( "example"
          , `Assoc [("before", `String g.before); ("after", `String g.after)] )
        ; ("verification", strings g.verification) ]

let render_once () =
  let seen = Hashtbl.create 16 in
  fun buf -> function
    | None -> ()
    | Some g when Hashtbl.mem seen g.id -> ()
    | Some g ->
        Hashtbl.add seen g.id () ;
        Buffer.add_string
          buf
          (Printf.sprintf "  coaching [%s/%s]: %s\n" catalog g.id g.intent) ;
        let lines label items =
          List.iter
            (fun s ->
              Buffer.add_string buf (Printf.sprintf "    %s: %s\n" label s) )
            items
        in
        lines "next" g.steps ;
        lines "avoid" g.avoid ;
        Buffer.add_string
          buf
          (Printf.sprintf "    example before: %s\n" g.before) ;
        Buffer.add_string buf (Printf.sprintf "    example after: %s\n" g.after) ;
        lines "verify" g.verification
