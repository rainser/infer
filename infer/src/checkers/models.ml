(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open ModelTables
open Utils
module L = Logging

(** Module for standard library models. *)

(* use library of inferred return annotations *)
let use_library = false

(* use model annotations for library functions *)
let use_models = true

(* libary functions: infer nullable annotation of return type *)
let infer_library_return = Config.from_env_variable "ERADICATE_LIBRARY"


(** Module for inference of parameter and return annotations. *)
module Inference = struct
  let enabled = false

  let get_dir () = Filename.concat !Config.results_dir "eradicate"

  let field_get_dir_fname fn =
    let fname = Ident.fieldname_to_string fn in
    (get_dir (), fname)

  let field_is_marked fn =
    let dir, fname = field_get_dir_fname fn in
    DB.read_file_with_lock dir fname <> None

  let proc_get_ret_dir_fname pname =
    let fname = Procname.to_filename pname ^ "_ret" in
    (get_dir (), fname)

  let proc_get_param_dir_fname pname =
    let fname = Procname.to_filename pname ^ "_params" in
    (get_dir (), fname)

  let update_count_str s_old =
    let n =
      if s_old = "" then 0
      else try int_of_string s_old with
        | Failure _ ->
            L.stderr "int_of_string %s@." s_old;
            assert false in
    string_of_int (n + 1)

  let update_boolvec_str _s size index bval =
    let s = if _s = "" then String.make size '0' else _s in
    String.set s index (if bval then '1' else '0');
    s

  let mark_file update_str dir fname =
    DB.update_file_with_lock dir fname update_str;
    match DB.read_file_with_lock dir fname with
    | Some buf -> L.stderr "Read %s: %s@." fname buf
    | None -> L.stderr "Read %s: None@." fname

  let mark_file_count = mark_file update_count_str

  (** Mark the field @Nullable indirectly by writing to a global file. *)
  let field_add_nullable_annotation fn =
    let dir, fname = field_get_dir_fname fn in
    mark_file_count dir fname

  (** Mark the return type @Nullable indirectly by writing to a global file. *)
  let proc_add_return_nullable pn =
    let dir, fname = proc_get_ret_dir_fname pn in
    mark_file_count dir fname

  (** Return true if the return type is marked @Nullable in the global file *)
  let proc_return_is_marked pname =
    let dir, fname = proc_get_ret_dir_fname pname in
    DB.read_file_with_lock dir fname <> None

  (** Mark the n-th parameter @Nullable indirectly by writing to a global file. *)
  let proc_add_parameter_nullable pn n tot =
    let dir, fname = proc_get_param_dir_fname pn in
    let update_str s = update_boolvec_str s tot n true in
    mark_file update_str dir fname

  (** Return None if the parameters are not marked, or a vector of marked parameters *)
  let proc_parameters_marked pn =
    let dir, fname = proc_get_param_dir_fname pn in
    match DB.read_file_with_lock dir fname with
    | None -> None
    | Some buf ->
        let boolvec = ref [] in
        String.iter (fun c -> boolvec := (c = '1') :: !boolvec) buf;
        Some (list_rev !boolvec)
end (* Inference *)


let table_has_procedure table proc_name =
  let proc_id = Procname.to_unique_id proc_name in
  try ignore (Hashtbl.find table proc_id); true
  with Not_found -> false

type table_t = (string, bool) Hashtbl.t

(* precomputed marshalled table of inferred return annotations. *)
let ret_library_table : table_t Lazy.t =
  lazy (Hashtbl.create 1)
(*
lazy (Marshal.from_string Eradicate_library.marshalled_library_table 0)
*)

(** Return the annotated signature of the procedure, taking into account models. *)
let get_annotated_signature callee_pdesc callee_pname =
  let annotated_signature =
    Annotations.get_annotated_signature
      Specs.proc_get_method_annotation callee_pdesc callee_pname in
  let proc_id = Procname.to_unique_id callee_pname in
  let infer_parameters ann_sig =
    let mark_par =
      if Inference.enabled then Inference.proc_parameters_marked callee_pname
      else None in
    match mark_par with
    | None -> ann_sig
    | Some bs ->
        let mark = (false, bs) in
        Annotations.annotated_signature_mark callee_pname Annotations.Nullable ann_sig mark in
  let infer_return ann_sig =
    let mark_r =
      let from_library =
        if use_library then
          try
            Hashtbl.find (Lazy.force ret_library_table) proc_id
          with Not_found -> false
        else false in
      let from_inference = Inference.enabled && Inference.proc_return_is_marked callee_pname in
      from_library || from_inference in
    if mark_r
    then Annotations.annotated_signature_mark_return callee_pname Annotations.Nullable ann_sig
    else ann_sig in
  let lookup_models_nullable ann_sig =
    if use_models then
      try
        let mark = Hashtbl.find annotated_table_nullable proc_id in
        Annotations.annotated_signature_mark callee_pname Annotations.Nullable ann_sig mark
      with Not_found ->
        ann_sig
    else ann_sig in
  let lookup_models_present ann_sig =
    if use_models then
      try
        let mark = Hashtbl.find annotated_table_present proc_id in
        Annotations.annotated_signature_mark callee_pname Annotations.Present ann_sig mark
      with Not_found ->
        ann_sig
    else ann_sig in
  let lookup_models_strict ann_sig =
    if use_models
       && Hashtbl.mem annotated_table_strict proc_id
    then
      Annotations.annotated_signature_mark_return_strict callee_pname ann_sig
    else
      ann_sig in

  annotated_signature
  |> lookup_models_nullable
  |> lookup_models_present
  |> lookup_models_strict
  |> infer_return
  |> infer_parameters

(** Return true when the procedure has been modelled for nullable. *)
let is_modelled_nullable proc_name =
  if use_models then
    let proc_id = Procname.to_unique_id proc_name in
    try ignore (Hashtbl.find annotated_table_nullable proc_id ); true
    with Not_found -> false
  else false

(** Return true when the procedure belongs to the library of inferred return annotations. *)
let is_ret_library proc_name =
  if use_library && not infer_library_return then
    let proc_id = Procname.to_unique_id proc_name in
    try ignore (Hashtbl.find (Lazy.force ret_library_table) proc_id); true
    with Not_found -> false
  else false

(** Check if the procedure is one of the known Preconditions.checkNotNull. *)
let is_check_not_null proc_name =
  table_has_procedure check_not_null_table proc_name

(** Parameter number for a procedure known to be a checkNotNull *)
let get_check_not_null_parameter proc_name =
  let proc_id = Procname.to_unique_id proc_name in
  try Hashtbl.find check_not_null_parameter_table proc_id
  with Not_found -> 0

(** Check if the procedure is one of the known Preconditions.checkState. *)
let is_check_state proc_name =
  table_has_procedure check_state_table proc_name

(** Check if the procedure is one of the known Preconditions.checkArgument. *)
let is_check_argument proc_name =
  table_has_procedure check_argument_table proc_name

(** Check if the procedure is Optional.get(). *)
let is_optional_get proc_name =
  table_has_procedure optional_get_table proc_name

(** Check if the procedure is Optional.isPresent(). *)
let is_optional_isPresent proc_name =
  table_has_procedure optional_isPresent_table proc_name

(** Check if the procedure is Map.containsKey(). *)
let is_containsKey proc_name =
  table_has_procedure containsKey_table proc_name