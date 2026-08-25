(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Turn the tail of a pipeline into a task}

    This module exists to be the only place in the program that closes a
    pipeline, which is what makes it the one home of the spurious-model
    policy: no branch can forget the [Mark_spurious] stage, and no backend
    can grant itself a shortcut the policy withholds.  [Transform] belongs
    to the [core] library and cannot hide the closing function from its
    users, so "only place" is kept true by a rule in this directory's [dune]
    file, which greps this file and [nunchaku.ml] for it. *)

open Nunchaku_core

module Tr = Nunchaku_transformations
module Res = Problem.Res

(* Decide the result a task reports and the shortcut it is granted, together.
   Both directions hold here, deliberately.  [Mark_spurious] may rewrite an
   [unsat] the encoding cannot vouch for into [Unknown], and such an answer
   must not end the race, since a sibling backend may still conclude; the
   other way round, a backend that asked to shortcut on an [Unknown] is
   overruled -- none does today, and an inconclusive answer has no business
   ending the race whoever asked for it.  A conclusive answer keeps the
   shortcut its backend asked for, in particular an [Error]: demoting that
   one would put a non-[Unknown] into the scheduler's result list, which
   [process_res_] rejects. *)
let decide_result_and_shortcut ret (x, shortcut) =
  let res = ret x in
  match res with
    | Res.Unknown _ -> res, Scheduling.No_shortcut
    | Res.Sat _ | Res.Unsat _ | Res.Error _ -> res, shortcut

let close_task p =
  Transform.Pipe.close (Transform.Pipe.compose (Tr.Mark_spurious.pipe ()) p)
    ~f:(fun task ret ->
      Scheduling.Task.map_res ~f:(decide_result_and_shortcut ret) task, CCFun.id)
