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

open Core_kernel
open ErrorUtils
open Result.Let_syntax
open MonadUtil
open Literal
open Syntax
open Scilla_crypto.Schnorr
open Datatypes.SnarkTypes

let scale_factor = Stdint.Uint64.of_int 8

(* Scale down the remaining gas to original metrics *)
let finalize_remaining_gas initial_gas_limit remaining_gas =
  let open Stdint in
  let remain = Uint64.div remaining_gas scale_factor in
  (* Ensure that at least one unit of gas is consumed. *)
  if Uint64.compare remain initial_gas_limit = 0 then
    Uint64.sub remain Uint64.one
  else remain

(* Arbitrarily picked, the largest prime less than 100. *)
let version_mismatch_penalty = 97

module ScillaGas (SR : Rep) (ER : Rep) = struct
  (* TODO: Change this to CanonicalLiteral = Literals based on canonical names. *)
  module GasLiteral = FlattenedLiteral
  module GasType = GasLiteral.LType
  module GI = GasType.TIdentifier
  module GasSyntax = ScillaSyntax (SR) (ER) (GasLiteral)
  open GasType
  open GasLiteral
  open GasSyntax

  (* The storage cost of a literal, based on it's size. *)
  let rec literal_cost lit =
    match lit with
    (* StringLits have fixed cost till a certain
         length and increased cost after that. *)
    | StringLit s ->
        let l = String.length s in
        pure @@ if l <= 20 then 20 else l
    | BNum _ -> pure @@ 64 (* Implemented using big-nums. *)
    (* (bit-width, value) *)
    | IntLit x -> pure @@ (int_lit_width x / 8)
    | UintLit x -> pure @@ (uint_lit_width x / 8)
    | ByStr bs -> pure @@ Bystr.width bs
    | ByStrX bs -> pure @@ Bystrx.width bs
    (* Message: an associative array *)
    | Msg m ->
        foldM
          ~f:(fun acc (s, lit') ->
            let%bind cs = literal_cost (StringLit s) in
            let%bind clit' = literal_cost lit' in
            pure (acc + cs + clit'))
          ~init:0 m
    (* A dynamic map of literals *)
    | Map (_, m) ->
        Caml.Hashtbl.fold
          (fun lit1 lit2 acc' ->
            let%bind acc = acc' in
            let%bind clit1 = literal_cost lit1 in
            let%bind clit2 = literal_cost lit2 in
            pure (acc + clit1 + clit2))
          m (pure 0)
    (* A constructor in HNF *)
    | ADTValue (cn, _, ll) as als ->
        (* Make a special case for Lists, to avoid overflowing recursion. *)
        if String.(cn = "Cons") then
          let rec walk elm acc_cost =
            match elm with
            | ADTValue ("Cons", _, [ l; ll ]) ->
                let%bind lcost = literal_cost l in
                walk ll (acc_cost + lcost)
            | ADTValue ("Nil", _, _) -> pure (acc_cost + 1)
            | _ -> fail0 "Malformed list while computing literal cost"
          in
          walk als 0
        else if List.is_empty ll then pure 1
        else
          foldM
            ~f:(fun acc lit' ->
              let%bind clit' = literal_cost lit' in
              pure (acc + clit'))
            ~init:0 ll
    (* Constant cost for forming a closure (similar to expr_static_cost below). *)
    | Clo _ -> pure @@ 1
    | TAbs _ -> pure @@ 1

  let rec map_sort_cost l =
    match l with
    | Map (_, kvlist) ->
        let sub_cost =
          Caml.Hashtbl.fold
            (fun _ vlit acc -> acc + map_sort_cost vlit)
            kvlist 0
        in
        let this_cost =
          let len = Caml.Hashtbl.length kvlist in
          if len > 0 then
            let log_len = Int.of_float (Float.log (Int.to_float len)) in
            len * log_len
          else 0
        in
        sub_cost + this_cost
    | _ -> 0

  let rec expr_static_cost e =
    let ee, erep = e in
    let e' =
      match ee with
      | Literal _ | Var _ | Message _ | App _ | Constr _ | TApp _ ->
          GasExpr (GasCharge.StaticCost 1, e)
      | Fixpoint (f, t, e') ->
          GasExpr
            ( GasCharge.StaticCost 1,
              (Fixpoint (f, t, expr_static_cost e'), erep) )
      | Fun (f, t, e') ->
          GasExpr
            (GasCharge.StaticCost 1, (Fun (f, t, expr_static_cost e'), erep))
      | TFun (f, e') ->
          GasExpr (GasCharge.StaticCost 1, (TFun (f, expr_static_cost e'), erep))
      | Let (i, t, lhs, rhs) ->
          GasExpr
            ( GasCharge.StaticCost 1,
              (Let (i, t, expr_static_cost lhs, expr_static_cost rhs), erep) )
      | MatchExpr (o, clauses) ->
          GasExpr
            ( GasCharge.StaticCost (List.length clauses),
              ( MatchExpr
                  ( o,
                    List.map clauses ~f:(fun (p, e') ->
                        (p, expr_static_cost e')) ),
                erep ) )
      | Builtin _
      (* We don't add costs for Builtin because we can't know it statically
       * without type info (Eval doesn't run the type checker). To know this
       * statically, call builtin_cost below, providing argument types. *)
      | GasExpr _ ->
          ee
    in
    (e', erep)

  (* this is a dynamic cost. *)
  let rec stmts_cost = function
    | [] -> []
    | (s, srep) :: rem_stmts ->
        let s' =
          match s with
          | Load (x, _) ->
              let g =
                GasStmt
                  (GasCharge.SumOf
                     ( GasCharge.SizeOf (GI.get_id x),
                       GasCharge.MapSortCost (GI.get_id x) ))
              in
              (* We charge *after* the load because we can't know the size before. *)
              [ (s, srep); (g, srep) ]
          | Store (_, v) | SendMsgs v | CreateEvnt v ->
              let g = GasStmt (GasCharge.SizeOf (GI.get_id v)) in
              [ (g, srep); (s, srep) ]
          | Bind (x, e) ->
            let g = GasStmt (GasCharge.StaticCost 1) in
            let s' = Bind (x, expr_static_cost e) in
            [ (g, srep); (s', srep) ]
          | ReadFromBC _ | CallProc _ ->
              let g = GasStmt (GasCharge.StaticCost 1) in
              [ (g, srep); (s, srep) ]
          | MapUpdate (_, klist, ropt) ->
              let n = GasCharge.StaticCost (List.length klist) in
              let g =
                match ropt with
                | Some r -> GasCharge.SumOf (GasCharge.SizeOf (GI.get_id r), n)
                | None -> n
              in
              [ (GasStmt g, srep); (s, srep) ]
          | MapGet (x, _, klist, _) ->
              let n = GasCharge.StaticCost (List.length klist) in
              let g =
                  GasCharge.SumOf
                    ( GasCharge.SumOf
                        ( GasCharge.SizeOf (GI.get_id x),
                          GasCharge.MapSortCost (GI.get_id x) ),
                      n )
              in
              [ (s, srep); (GasStmt g, srep) ]
          | MatchStmt (x, clauses) ->
              let g = GasCharge.StaticCost (List.length clauses) in
              let clauses' =
                List.map clauses ~f:(fun (p, stmts) ->
                    let stmts' = stmts_cost stmts in
                    (p, stmts'))
              in
              let s' = MatchStmt (x, clauses') in
              [ (GasStmt g, srep); (s', srep) ]
          | AcceptPayment ->
              let g = GasStmt (GasCharge.StaticCost 1) in
              [ (g, srep); (s, srep) ]
          | Iterate (l, _) ->
              let g = GasStmt (GasCharge.LengthOf (GI.get_id l)) in
              [ (g, srep); (s, srep) ]
          | Throw _ (* TODO: Throw should charge same as event and send. *)
          | GasStmt _ ->
              [ (s, srep) ]
        in
        s' @ stmts_cost rem_stmts

  let lib_entry_cost = function
    | LibVar (v, topt, e) -> LibVar (v, topt, expr_static_cost e)
    | LibTyp _ as le -> le

  let lib_cost lib =
    { lib with lentries = List.map lib.lentries ~f:lib_entry_cost }

  let rec libtree_cost ltree =
    let deps' = List.map ltree.deps ~f:libtree_cost in
    let libn' = lib_cost ltree.libn in
    { libn = libn'; deps = deps' }

  let lmod_cost lmod = { lmod with libs = lib_cost lmod.libs }

  let cmod_cost (cmod : cmodule) =
    let contr_cost contr =
      let comp_cost comp =
        { comp with comp_body = stmts_cost comp.comp_body }
      in
      {
        contr with
        cconstraint = expr_static_cost contr.cconstraint;
        cfields =
          List.map contr.cfields ~f:(fun (i, t, e) ->
              (i, t, expr_static_cost e));
        ccomps = List.map contr.ccomps ~f:comp_cost;
      }
    in
    {
      cmod with
      libs = Option.map cmod.libs ~f:lib_cost;
      contr = contr_cost cmod.contr;
    }

  (* A signature for functions that determine dynamic cost of built-in ops. *)
  (* op -> arguments -> base cost -> total cost *)
  type coster =
    builtin ->
    ER.rep GI.t list ->
    GasType.t list ->
    (GasCharge.gas_charge, scilla_error list) result

  (* op, arg types, coster, base cost. *)
  type builtin_record = builtin * GasType.t list * coster

  let string_coster op args _arg_types =
    match (op, args) with
    | Builtin_eq, [ s1; s2 ] ->
        pure
        @@ GasCharge.MinOf
             (GasCharge.SizeOf (GI.get_id s1), GasCharge.SizeOf (GI.get_id s2))
    | Builtin_concat, [ s1; s2 ] ->
        pure
        @@ GasCharge.SumOf
             (GasCharge.SizeOf (GI.get_id s1), GasCharge.SizeOf (GI.get_id s2))
    | Builtin_substr, [ s; i1; i2 ] ->
        pure
        @@ GasCharge.MinOf
             ( GasCharge.SizeOf (GI.get_id s),
               GasCharge.SumOf
                 ( GasCharge.ValueOf (GI.get_id i1),
                   GasCharge.ValueOf (GI.get_id i2) ) )
    | Builtin_strlen, [ s ] -> pure @@ GasCharge.SizeOf (GI.get_id s)
    | Builtin_to_string, [ l ] -> pure @@ GasCharge.SizeOf (GI.get_id l)
    | _ -> fail0 @@ "Gas cost error for string built-in"

  let crypto_coster op args types =
    match (op, types, args) with
    | Builtin_eq, [ PrimType Bystr_typ; PrimType Bystr_typ ], [ a1; _ ] ->
        pure @@ GasCharge.SizeOf (GI.get_id a1)
    | Builtin_eq, [ a1; a2 ], _
      when is_bystrx_type a1 && is_bystrx_type a2
           && Option.(value_exn (bystrx_width a1) = value_exn (bystrx_width a2))
      ->
        let width = Option.value_exn (bystrx_width a1) in
        pure @@ GasCharge.StaticCost width
    | Builtin_to_uint256, [ a ], _
      when is_bystrx_type a && Option.value_exn (bystrx_width a) <= 32 ->
        pure @@ GasCharge.StaticCost 32
    | Builtin_sha256hash, _, [ a ] | Builtin_schnorr_get_address, _, [ a ] ->
        (* Block size of sha256hash is 512 *)
        let s = GasCharge.SizeOf (GI.get_id a) in
        let n = GasCharge.StaticCost (64 * 15) in
        pure (GasCharge.DivCeil (s, n))
    | Builtin_keccak256hash, _, [ a ] ->
        (* Block size of keccak256hash is 1088 *)
        let s = GasCharge.SizeOf (GI.get_id a) in
        let n = GasCharge.StaticCost (136 * 15) in
        pure (GasCharge.DivCeil (s, n))
    | Builtin_ripemd160hash, _, [ a ] ->
        (* Block size of ripemd160hash is 512 *)
        let s = GasCharge.SizeOf (GI.get_id a) in
        let n = GasCharge.StaticCost (64 * 15) in
        pure (GasCharge.DivCeil (s, n))
    | Builtin_schnorr_verify, _, [ _; s; _ ]
    | Builtin_ecdsa_verify, _, [ _; s; _ ] ->
        (* x = div_ceil (Bystr.width s + 66) 64 *)
        let x =
          GasCharge.DivCeil
            ( GasCharge.SumOf
                (GasCharge.SizeOf (GI.get_id s), GasCharge.StaticCost 66),
              GasCharge.StaticCost 64 )
        in
        (* (250 + (15 * x)) *)
        pure
          (GasCharge.SumOf
             ( GasCharge.StaticCost 250,
               GasCharge.ProdOf (GasCharge.StaticCost 15, x) ))
    | Builtin_to_bystr, [ a ], _ when is_bystrx_type a ->
        pure (GasCharge.StaticCost (Option.value_exn (bystrx_width a)))
    | Builtin_bech32_to_bystr20, _, [ prefix; addr ]
    | Builtin_bystr20_to_bech32, _, [ prefix; addr ] ->
        let base = 4 in
        pure
          (GasCharge.ProdOf
             ( GasCharge.SumOf
                 ( GasCharge.SizeOf (GI.get_id prefix),
                   GasCharge.SizeOf (GI.get_id addr) ),
               GasCharge.StaticCost base ))
    | Builtin_concat, [ a1; a2 ], _ when is_bystrx_type a1 && is_bystrx_type a2
      ->
        pure
          (GasCharge.StaticCost
             Option.(value_exn (bystrx_width a1) + value_exn (bystrx_width a2)))
    | Builtin_alt_bn128_G1_add, _, _ -> pure (GasCharge.StaticCost 20)
    | Builtin_alt_bn128_G1_mul, _, [ _; s ] ->
        let multiplier = GasCharge.LogOf (GI.get_id s) in
        pure @@ GasCharge.ProdOf (GasCharge.StaticCost 20, multiplier)
    | Builtin_alt_bn128_pairing_product, _, [ pairs ] ->
        let list_len = GasCharge.LengthOf (GI.get_id pairs) in
        pure (GasCharge.ProdOf (GasCharge.StaticCost 40, list_len))
    | _ -> fail0 @@ "Gas cost error for hash built-in"

  let map_coster op args _arg_types =
    match args with
    | m :: _ -> (
        (* size, get and contains do not make a copy of the Map, hence constant. *)
        match op with
        | Builtin_size | Builtin_get | Builtin_contains ->
            pure (GasCharge.StaticCost 1)
        | _ ->
            pure
              (GasCharge.SumOf
                 (GasCharge.StaticCost 1, GasCharge.LengthOf (GI.get_id m))) )
    | _ -> fail0 @@ "Gas cost error for map built-in"

  let to_nat_coster _ args _arg_types =
    match args with
    | [ a ] -> pure (GasCharge.ValueOf (GI.get_id a))
    | _ -> fail0 @@ "Gas cost error for to_nat built-in"

  let int_conversion_coster w _ _args arg_types =
    let base = 4 in
    match arg_types with
    | [ PrimType (Uint_typ _) ]
    | [ PrimType (Int_typ _) ]
    | [ PrimType String_typ ] ->
        if w = 32 || w = 64 then pure (GasCharge.StaticCost base)
        else if w = 128 then pure (GasCharge.StaticCost (base * 2))
        else if w = 256 then pure (GasCharge.StaticCost (base * 4))
        else fail0 @@ "Gas cost error for integer conversion"
    | _ -> fail0 @@ "Gas cost due to incorrect arguments for int conversion"

  let int_coster op args arg_types =
    let base = 4 in
    let%bind base' =
      match op with
      | Builtin_mul | Builtin_div | Builtin_rem ->
          pure (GasCharge.StaticCost (5 * base))
      | Builtin_pow -> (
          match args with
          | [ _; p ] ->
              pure
                (GasCharge.ProdOf
                   ( GasCharge.StaticCost (base * 5),
                     GasCharge.ValueOf (GI.get_id p) ))
          | _ -> fail0 @@ "Gas cost error for built-in pow" )
      | Builtin_isqrt -> (
          match args with
          | [ a ] ->
              pure
                (GasCharge.ProdOf
                   (GasCharge.StaticCost base, GasCharge.LogOf (GI.get_id a)))
          | _ -> fail0 "Invalid argument type to isqrt" )
      | _ -> pure (GasCharge.StaticCost base)
    in
    let%bind w =
      match arg_types with
      | a :: _ -> (
          match int_width a with
          | Some w -> pure w
          | None -> fail0 "int_coster: cannot determine integer width" )
      | _ -> fail0 @@ "Gas cost error for integer built-in"
    in
    if w = 32 || w = 64 then pure base'
    else if w = 128 then pure (GasCharge.ProdOf (base', GasCharge.StaticCost 2))
    else if w = 256 then pure (GasCharge.ProdOf (base', GasCharge.StaticCost 4))
    else fail0 @@ "Gas cost error for integer built-in"

  let bnum_coster _op _args _arg_types = pure (GasCharge.StaticCost 32)

  let tvar s = TypeVar s

  [@@@ocamlformat "disable"]

  (* built-in op costs are propotional to size of data they operate on. *)
  let builtin_records : builtin_record list = [
     (* Strings *)
    (Builtin_eq, [string_typ;string_typ], string_coster);
    (Builtin_concat, [string_typ;string_typ], string_coster);
    (Builtin_substr, [string_typ; tvar "'A"; tvar "'A"], string_coster);
    (Builtin_strlen, [string_typ], string_coster);
    (Builtin_to_string, [tvar "'A"], string_coster);
  
    (* Block numbers *)
    (Builtin_eq, [bnum_typ;bnum_typ], bnum_coster);
    (Builtin_blt, [bnum_typ;bnum_typ], bnum_coster);
    (Builtin_badd, [bnum_typ;tvar "'A"], bnum_coster);
    (Builtin_bsub, [bnum_typ;bnum_typ], bnum_coster);
  
    (* Crypto *)
    (Builtin_eq, [tvar "'A"; tvar "'A"], crypto_coster);
    (Builtin_to_bystr, [tvar "'A"], crypto_coster);
    (Builtin_bech32_to_bystr20, [string_typ;string_typ], crypto_coster);
    (Builtin_bystr20_to_bech32, [string_typ;bystrx_typ address_length], crypto_coster);
    (Builtin_to_uint256, [tvar "'A"], crypto_coster);
    (Builtin_sha256hash, [tvar "'A"], crypto_coster);
    (Builtin_keccak256hash, [tvar "'A"], crypto_coster);
    (Builtin_ripemd160hash, [tvar "'A"], crypto_coster);
    (Builtin_schnorr_verify, [bystrx_typ pubkey_len; bystr_typ; bystrx_typ signature_len], crypto_coster);
    (Builtin_ecdsa_verify, [bystrx_typ Secp256k1Wrapper.pubkey_len; bystr_typ; bystrx_typ Secp256k1Wrapper.signature_len], crypto_coster);
    (Builtin_concat, [tvar "'A"; tvar "'A"], crypto_coster);
    (Builtin_schnorr_get_address, [bystrx_typ pubkey_len], crypto_coster);
    (Builtin_alt_bn128_G1_add, [g1point_type; g1point_type], crypto_coster);
    (Builtin_alt_bn128_G1_mul, [g1point_type; scalar_type], crypto_coster);
    (Builtin_alt_bn128_pairing_product, [g1g2pair_list_type], crypto_coster);
  
    (* Maps *)
    (Builtin_contains, [tvar "'A"; tvar "'A"], map_coster);
    (Builtin_put, [tvar "'A"; tvar "'A"; tvar "'A"], map_coster);
    (Builtin_get, [tvar "'A"; tvar "'A"], map_coster);
    (Builtin_remove, [tvar "'A"; tvar "'A"], map_coster);
    (Builtin_to_list, [tvar "'A"], map_coster);
    (Builtin_size, [tvar "'A"], map_coster);
  
    (* Integers *)
    (Builtin_eq, [tvar "'A"; tvar "'A"], int_coster);
    (Builtin_lt, [tvar "'A"; tvar "'A"], int_coster);
    (Builtin_add, [tvar "'A"; tvar "'A"], int_coster);
    (Builtin_sub, [tvar "'A"; tvar "'A"], int_coster);
    (Builtin_mul, [tvar "'A"; tvar "'A"], int_coster);
    (Builtin_div, [tvar "'A"; tvar "'A"], int_coster);
    (Builtin_rem, [tvar "'A"; tvar "'A"], int_coster);
    (Builtin_pow, [tvar "'A"; uint32_typ], int_coster);
    (Builtin_isqrt, [tvar "'A"], int_coster);
  
    (Builtin_to_int32, [tvar "'A"], int_conversion_coster 32);
    (Builtin_to_int64, [tvar "'A"], int_conversion_coster 64);
    (Builtin_to_int128, [tvar "'A"], int_conversion_coster 128);
    (Builtin_to_int256, [tvar "'A"], int_conversion_coster 256);
    (Builtin_to_uint32, [tvar "'A"], int_conversion_coster 32);
    (Builtin_to_uint64, [tvar "'A"], int_conversion_coster 64);
    (Builtin_to_uint128, [tvar "'A"], int_conversion_coster 128);
    (Builtin_to_uint256, [tvar "'A"], int_conversion_coster 256);
  
    (Builtin_to_nat, [uint32_typ], to_nat_coster);
  ]

  [@@@ocamlformat "enable"]

  let builtin_hashtbl =
    let open Caml in
    let ht : (builtin, builtin_record list) Hashtbl.t = Hashtbl.create 64 in
    List.iter
      (fun row ->
        let opname, _, _ = row in
        match Hashtbl.find_opt ht opname with
        | Some p -> Hashtbl.add ht opname (row :: p)
        | None -> Hashtbl.add ht opname [ row ])
      builtin_records;
    ht

  let builtin_cost (op, _) arg_types arg_ids =
    let matcher (name, types, fcoster) =
      (* The names and type list lengths must match and *)
      if
        [%equal: Syntax.builtin] name op
        && List.length types = List.length arg_types
        && List.for_all2_exn
             ~f:(fun t1 t2 ->
               (* the types should match *)
               [%equal: GasType.t] t1 t2
               ||
               (* or the built-in record is generic *)
               match t2 with TypeVar _ -> true | _ -> false)
             arg_types types
      then fcoster op arg_ids arg_types (* this can fail too *)
      else fail0 @@ "Name or arity doesn't match"
    in
    let msg =
      sprintf "Unable to determine gas cost for \"%s\"" (pp_builtin op)
    in
    let dict =
      match Caml.Hashtbl.find_opt builtin_hashtbl op with
      | Some rows -> rows
      | None -> []
    in
    let%bind _, cost = tryM dict ~f:matcher ~msg:(fun () -> mk_error0 msg) in
    pure cost
end
