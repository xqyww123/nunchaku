(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Maps whose [to_list] order does not change with the OCaml version}

    [CCMap.Make] does not give the same [to_list] on every compiler.  Containers
    defines its own [to_list] as a fold that conses, which yields the bindings in
    {b descending} key order -- but only under [\[@@@iflt 5.1\]], i.e. below OCaml
    5.1.  From OCaml 5.1 on, containers omits it and the stdlib's own
    [Map.to_list] shows through, which yields {b ascending} key order.  Same
    containers, same sources, opposite lists: with containers 3.18, OCaml 4.14
    prints [3,2,1] where OCaml 5.4 prints [1,2,3].

    Nunchaku keys most of its maps on [ID.t], which compares on a global counter,
    so that reversal reaches the user: it flips the order of the branches printed
    for a [match], and the order of the constructors emitted in an SMT-LIB
    datatype declaration.  Every map in nunchaku is therefore built with this
    functor instead of [CCMap.Make], which pins [to_list] to ascending key order
    on every compiler -- the same order as [iter], [fold] and [bindings], and,
    for a datatype's constructors, the order they were declared in.

    A [dune runtest] rule in [src/dune] keeps [CCMap.Make] out of the rest of the
    tree so that a new map cannot quietly reintroduce the version dependency. *)

module Make (O : Map.OrderedType) = struct
  include CCMap.Make (O)

  (* [bindings] is stdlib's, ascending, and identical on every OCaml version. *)
  let to_list = bindings
end
