(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id: bytegen.mli 11156 2011-07-27 14:17:02Z doligez $ *)

(* Generation of bytecode from lambda terms *)

open Lambda
open Instruct

val compile_implementation: string -> lambda -> instruction list
val compile_phrase: lambda -> instruction list * instruction list

val reset_bytegen: unit -> unit
