(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Merge the problem metadata into the backend's answer}

    The single place where the two "the answer may lie" flags computed by
    the encoding pipeline are merged into a result:

    - [sat_means_unknown]: the model may be spurious, so mark it;
    - [unsat_means_unknown]: models were lost, so the [unsat] claims
      nothing and becomes [Unknown].

    Every backend goes through this stage, because [close_task] (in
    [nunchaku.ml]) composes it itself; it acts after the whole decode
    chain, so a backend that rebuilds the model from scratch (kodkod,
    through [FoToRelational]) cannot lose the mark. Backends must not
    duplicate it. *)

open Nunchaku_core

val name : string

val pipe :
  unit ->
  (('t1, 'ty1) Problem.t, ('t1, 'ty1) Problem.t,
   ('t2, 'ty2) Problem.Res.t, ('t2, 'ty2) Problem.Res.t) Transform.t
