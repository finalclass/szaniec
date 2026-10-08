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
  ; gaps: Observation.gap list }
