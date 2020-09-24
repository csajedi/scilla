(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.
  
  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.
 
  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 
  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

(* This file describes function that communicate with the blockchain to fetch
 * and update state variables on demand. *)

open Scilla_base
open Literal
open ErrorUtils

(* TODO: Change this to CanonicalLiteral = Literals based on canonical names. *)
module SSLiteral = FlattenedLiteral
module SSType = SSLiteral.LType
module SSIdentifier = SSType.TIdentifier

type ss_field = {
  fname : string;
  ftyp : SSType.t;
  fval : SSLiteral.t option; (* Value may not be available (in IPC mode) *)
}

type service_mode =
  | IPC of string
  (* port number for IPC *)
  | Local

(* [ Initialization of StateService ]

  We have two service modes currently, one via an inter-process-communication
  with the blockchain and the other via the full state provided as an input
  to the interpreter. The IPC mode is on-demand, which means that only parts
  of the state that are necessary are fetched / updated, not all of it.

  While the below API provides a uniform interface for fetching and updating
  states for either modes, setting up a new contract (deployment) requires
  more care. At the time of deployment, a remote database (i.e., IPC  mode)
  needs to be updated with the initial state values. This requires a call
  to the `update` function below for each state variable. On the other hand,
  for the `Local` mode, the StateService module is directly initialized with
  the field values (`fval` of `ss_field` will not be `None`) on every run,
  not just deployment.

*)

(* Sets up the state service object. Should be called before any queries. *)
val initialize : sm:service_mode -> fields:ss_field list -> unit

(* Expensive operation, use with care. *)
val get_full_state :
  unit -> ((string * SSLiteral.t) list, scilla_error list) result

(* Finalize: no more queries. *)
val finalize : unit -> (unit, scilla_error list) result

(* Fetch from a field. "keys" is empty when fetching non-map fields or an entire Map field.
 * If a map key is not found, then None is returned, otherwise (Some value) is returned. *)
val fetch :
  fname:loc SSIdentifier.t ->
  keys:SSLiteral.t list ->
  (SSLiteral.t option, scilla_error list) result

(* Update a field. "keys" is empty when updating non-map fields or an entire Map field. *)
val update :
  fname:loc SSIdentifier.t ->
  keys:SSLiteral.t list ->
  value:SSLiteral.t ->
  (unit, scilla_error list) result

(* Is a key in a map. keys must be non-empty. *)
val is_member :
  fname:loc SSIdentifier.t ->
  keys:SSLiteral.t list ->
  (bool, scilla_error list) result

(* Remove a key from a map. keys must be non-empty. *)
val remove :
  fname:loc SSIdentifier.t ->
  keys:SSLiteral.t list ->
  (unit, scilla_error list) result

(* Should rarely be used, and is useful only when multiple StateService objects are required *)
module MakeStateService () : sig
  val initialize : sm:service_mode -> fields:ss_field list -> unit

  val get_full_state :
    unit -> ((string * SSLiteral.t) list, scilla_error list) result

  val finalize : unit -> (unit, scilla_error list) result

  val fetch :
    fname:loc SSIdentifier.t ->
    keys:SSLiteral.t list ->
    (SSLiteral.t option, scilla_error list) result

  val update :
    fname:loc SSIdentifier.t ->
    keys:SSLiteral.t list ->
    value:SSLiteral.t ->
    (unit, scilla_error list) result

  val is_member :
    fname:loc SSIdentifier.t ->
    keys:SSLiteral.t list ->
    (bool, scilla_error list) result

  val remove :
    fname:loc SSIdentifier.t ->
    keys:SSLiteral.t list ->
    (unit, scilla_error list) result
end
