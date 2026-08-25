(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Merge the problem metadata into the backend's answer} *)

open Nunchaku_core

module Res = Problem.Res
module Meta = ProblemMetadata

let name = "mark_spurious"
let section = Utils.Section.make name

let decode (meta:Meta.t) (res:('t,'ty) Res.t) : ('t,'ty) Res.t =
  match res with
    | Res.Sat (m, i) when meta.Meta.sat_means_unknown ->
      Res.Sat ({m with Model.potentially_spurious=true}, i)
    | Res.Unsat i when meta.Meta.unsat_means_unknown ->
      (* the encoding lost models, so this "unsat" claims nothing *)
      Res.Unknown [Res.U_incomplete i]
    | r -> r

let encode pb =
  let meta = Problem.metadata pb in
  Utils.debugf ~lock:true ~section 1
    "@[<2>metadata: sat_means_unknown=%B,@ unsat_means_unknown=%B@]"
    (fun k -> k meta.Meta.sat_means_unknown meta.Meta.unsat_means_unknown);
  pb, meta

let pipe () =
  Transform.make ~name ~encode ~decode ()
