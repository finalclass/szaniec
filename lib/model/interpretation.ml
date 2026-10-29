(* Interpretation model. Mirrors docs/contracts/interpretation-schema.md. *)

type kind =
  | ServiceRequest
  | ImplementationAccess
  | ResourceAccess
  | Registration
  | ExternalCall
  | QueuedCommand
  | Publication
  | Subscription

type ownership_class =
  | Contract_of of string
  | Contract_data of string
  | Implementation_of of string
  | Helper_of of string
  | CompositionRoot
  | ExternalLibrary of string
  | Unclassified

type ownership =
  { owner_module: string
  ; owner_class: ownership_class
  ; owner_service: string (* service name when the class names one, else "" *)
  }

type interaction =
  { kind: kind
  ; from_owner: string (* owning boundary of the origin *)
  ; to_service: string (* target service name when applicable *)
  ; to_method: string (* called rpc method when applicable *)
  ; target_module: string
  ; resource: string (* for ResourceAccess *)
  ; api: string (* resolved callee path *)
  ; evidence_path: string list (* symbols from boundary origin to the call *)
  ; sites: Observation.site list }

type binding =
  { binding_service: string
  ; binding_kind: string (* "registration" | "route-handler" | "make-spec" *)
  ; binding_module: string }

type repetition =
  { kind: string
  ; site: Observation.site
  ; api: string }

type execution_context =
  { origin: string
  ; site: Observation.site
  ; context_path: string list
  ; loops: repetition list
  ; activations: repetition list
  ; unknown_reasons: string list }

type execution_interaction =
  { execution_origin: Observation.execution_definition
  ; execution_owner: string
  ; execution_interaction: interaction
  ; execution_context: execution_context }

type flow_step =
  | Flow_call of interaction
  | Flow_choice of (string * flow_step list) list
  | Flow_loop of
      string * Observation.site * string * flow_step list * flow_step list
  | Flow_exit of string * Observation.site
  | Flow_unknown of string * Observation.site

type flow =
  { complete: bool
  ; steps: flow_step list }

type execution_flow =
  { flow_origin: Observation.execution_definition
  ; flow_owner: string
  ; flow: flow }

type callback_phase =
  | Same_path
  | Independent
  | Deferred
  | Unknown_callback

type callback_evidence =
  { callback_site: Observation.site
  ; callback_callee: string
  ; callback_target: string
  ; callback_resumed: bool
  ; callback_phase: callback_phase }

let kind_name = function
  | ServiceRequest -> "service-request"
  | ImplementationAccess -> "implementation-access"
  | ResourceAccess -> "resource-access"
  | Registration -> "registration"
  | ExternalCall -> "external-call"
  | QueuedCommand -> "queued-command"
  | Publication -> "publication"
  | Subscription -> "subscription"

let class_name = function
  | Contract_of s -> "contract of " ^ s
  | Contract_data s -> "contract data " ^ s
  | Implementation_of s -> "implementation of " ^ s
  | Helper_of s -> "helper of " ^ s
  | CompositionRoot -> "composition root"
  | ExternalLibrary s -> "external library " ^ s
  | Unclassified -> "unclassified"

type t =
  { ownerships: ownership list (* sorted by module path *)
  ; bindings: binding list (* sorted *)
  ; interactions: interaction list (* sorted, deduplicated *)
  ; execution_interactions: execution_interaction list
  ; execution_flows: execution_flow list
  ; callbacks: callback_evidence list
  ; callback_paths: (Observation.site * string list list) list
  ; bound_parameters: string list
  ; parameter_targets: (string * string list) list
  ; returned_calls: (Observation.site * string * string) list
  ; parameter_defaults: (string * string) list
  ; incomplete_calls: Observation.site list
  ; deferred_calls: Observation.site list
  ; gaps: Observation.gap list }
