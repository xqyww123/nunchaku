(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Interface to cvc5} *)

open Nunchaku_core
module E = CCResult
module Res = Problem.Res
module S = Scheduling

type id = ID.t

let name = "cvc5"
let section = Utils.Section.make name
let fpf = Format.fprintf

type model_term = FO.T.t
type model_ty = FO.Ty.t

module DSexp = Sexp_lib.Decoder

(* [Error] is for nunchaku's own broken invariants -- those that cannot depend
   on what the solver said, i.e. everything up to and including printing the
   problem.  Anything the solver sends that we cannot understand is
   [Backend_err]: every failure of the decoder, from [find_atom_] down, is one.
   [read_res_] turns [Backend_err] into [Res.Unknown [U_backend_error]] and
   catches anything else the decoder throws, so one unusable reply costs this
   arm and nothing else. *)
exception Error of string
exception Backend_err of string

let error_ e = raise (Error e)
let errorf_ fmt = CCFormat.ksprintf fmt ~f:error_
let cvc5_error_ msg = raise (Backend_err msg)
let backend_errorf_ fmt = CCFormat.ksprintf fmt ~f:cvc5_error_

let () =
  Printexc.register_printer (function
    | Error msg ->
        Some (Utils.err_sprintf "@[in the interface to cvc5:@ %s@]" msg)
    | _ -> None)

module T = FO.T
module Ty = FO.Ty

type problem = (T.t, Ty.t) FO.Problem.t
type symbol_kind = Model.symbol_kind

type decoded_sym =
  | ID of id (* regular fun *)
  | De_bruijn of int * Ty.t (* index to mu-binder *)
  | DataTest of id
  | DataSelect of id * int

(* a ground type, such as [to a (list b)] *)
type ground_ty = Ty.t

let gty_make = Ty.app
let gty_const id = gty_make id []

module GTy_map = Ordered_map.Make (FO.Ty)

let gty_head ty =
  match Ty.view ty with FO.TyApp (id, _) -> Some id | FO.TyBuiltin _ -> None

let rec fobackty_of_ground_ty g =
  match Ty.view g with
  | FO.TyApp (id, l) -> Ty.app id (List.map fobackty_of_ground_ty l)
  | FO.TyBuiltin b -> Ty.builtin b

type model_query =
  | Q_const
  (* we want to know the value of this constant *)
  | Q_fun of int
  (* we want to know the value of this function (int: arity) *)
  | Q_type of ground_ty
(* [id -> ty] means that [id : ty] is a dummy value, and we  want
     to know the finite domain of [ty] by asking [get-model-domain-elements] *)

let is_simple_query q =
  match q with Q_const | Q_fun _ -> true | Q_type _ -> false

let is_card_query q =
  match q with Q_const | Q_fun _ -> false | Q_type _ -> true

type decode_state = {
  kinds : symbol_kind ID.Map.t;
  (* ID -> its kind *)
  id_to_name : string ID.Tbl.t;
  (* maps ID to unique names *)
  name_to_id : (string, decoded_sym) Hashtbl.t;
  (* map (stringof ID) -> ID, and other builtins *)
  symbols : model_query ID.Tbl.t;
  (* set of symbols to ask values for in the model *)
  vars : Ty.t Var.t ID.Tbl.t;
  (* variables in scope *)
  let_vars : (string, model_term) Hashtbl.t;
  (* let variables in scope together with their value *)
  db_prefixes : (string, ground_ty) Hashtbl.t;
  (* prefixes expected for De Bruijn indices *)
  timer : Utils.Time.timer;
  (* time elapsed *)
  mutable db_stack : Ty.t Var.t option ref list;
  (* stack of variables for mu-binders, with a bool ref.
     If the ref is true, it means the variable is used at least once *)
  mutable witnesses : ID.t GTy_map.t; (* type -> witness of this type *)
}

let create_decode_state ~kinds () =
  {
    kinds;
    id_to_name = ID.Tbl.create 32;
    name_to_id = Hashtbl.create 32;
    symbols = ID.Tbl.create 32;
    db_prefixes = Hashtbl.create 8;
    db_stack = [];
    timer = Utils.Time.start_timer ();
    vars = ID.Tbl.create 32;
    let_vars = Hashtbl.create 32;
    witnesses = GTy_map.empty;
  }

(* the solver is dealt with through stdin/stdout *)
type t = {
  oc : out_channel;
  fmt : Format.formatter; (* prints on [oc] *)
  ic : in_channel;
  decode : decode_state;
  print_model : bool;
  options : string;
  sexp : DSexp.t;
  mutable closed : bool;
  mutable res : (T.t, Ty.t) Problem.Res.t option;
}

let name = "cvc5"

let close s =
  if not s.closed then (
    s.closed <- true;
    (* quite cvc5 and stop process *)
    try
      Format.pp_print_flush s.fmt ();
      output_string s.oc "(exit)\n";
      flush s.oc;
      close_in_noerr s.ic;
      close_out_noerr s.oc
    with _ -> ())

let create_ ~options ~print_model ~decode (ic, oc) =
  (* the [t] instance *)
  let s =
    {
      oc;
      fmt = Format.formatter_of_out_channel oc;
      ic;
      options;
      print_model;
      decode;
      closed = false;
      sexp = DSexp.of_lexbuf (Lexing.from_channel ic);
      res = None;
    }
  in
  Gc.finalise close s;
  (* close on finalize *)
  s

let pp_list ?(sep = " ") pp = Utils.pp_list ~sep pp

(* add numeric suffix to [name] until it is an unused name *)
let find_unique_name_ ~decode name0 =
  if not (Hashtbl.mem decode.name_to_id name0) then name0
  else
    let n = ref 0 in
    while Hashtbl.mem decode.name_to_id (Printf.sprintf "%s_%d" name0 !n) do
      incr n
    done;
    Printf.sprintf "%s_%d" name0 !n

(* injection from ID to string *)
let id_to_name ~decode id =
  try ID.Tbl.find decode.id_to_name id
  with Not_found ->
    let name0 =
      match (ID.name id, ID.polarity id) with
      | s, Polarity.NoPol -> s ^ "_" (* avoid clashes with cvc5 builtins *)
      | s, Polarity.Pos -> s ^ "_+"
      | s, Polarity.Neg -> s ^ "_-"
    in
    let name = find_unique_name_ ~decode name0 in
    Hashtbl.add decode.name_to_id name (ID id);
    ID.Tbl.add decode.id_to_name id name;
    name

let pp_builtin_cvc5 out = function
  | `Unitype -> assert false
  | `Prop -> CCFormat.string out "Bool"

(* print ground type using cvc5's escaping rules *)
let rec pp_gty ~decode out g =
  let normalize_str =
    String.map (fun c ->
        match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> c | _ -> '_')
  in
  match Ty.view g with
  | FO.TyBuiltin b -> pp_builtin_cvc5 out b
  | FO.TyApp (id, []) ->
      CCFormat.string out (id_to_name ~decode id |> normalize_str)
  | FO.TyApp (id, l) ->
      fpf out "_%s_%a_"
        (id_to_name ~decode id |> normalize_str)
        (pp_list ~sep:"_" (pp_gty ~decode))
        l

(* The single description of how a ground type is spelled to cvc5: an atom
   [a__] for a base sort, a list [(to_ a_ b_)] for a compound one.  The problem
   printer emits it and the domain parser compares a reply against it, and both
   go through here so the two spellings cannot drift apart -- if they did, every
   compound witness sort would be rejected.

   [pp_gty] above is a different, lossy spelling of the same type: it mangles
   every non-alphanumeric character and flattens application to [_to__a__b__].
   It is right for building cvc5's constant-name prefixes and wrong for
   comparing against a reply, so the two must not be confused. *)
let rec sexp_of_gty_ ~name g : Sexp_lib.t =
  match Ty.view g with
  | FO.TyBuiltin b -> `Atom (CCFormat.sprintf "%a" pp_builtin_cvc5 b)
  | FO.TyApp (id, []) -> `Atom (name id)
  | FO.TyApp (id, l) ->
      (* head first, then left to right: in the declaring direction [name]
         allocates a name for an id it has not seen, so evaluation order is
         what decides which id gets which name.  Neither constructor argument
         order nor [List.map]'s order is specified, so neither is relied on. *)
      let head = `Atom (name id) in
      let args = List.rev (List.rev_map (sexp_of_gty_ ~name) l) in
      `List (head :: args)

(* declaring: printing an id for the first time is what names it *)
let sexp_of_gty_decl ~decode = sexp_of_gty_ ~name:(id_to_name ~decode)

(* comparing against a reply: registers nothing, so a rejected reply leaves no
   trace.  An unnamed id here would mean comparing against a spelling cvc5 was
   never given -- our invariant, not the solver's doing, hence [Error]. *)
let sexp_of_gty ~decode =
  sexp_of_gty_ ~name:(fun id ->
      match ID.Tbl.find_opt decode.id_to_name id with
      | Some n -> n
      | None -> errorf_ "no name was declared to cvc5 for %a" ID.pp id)

(* the prefix used by cvc5 for constants of the given type *)
let const_of_ty ~decode gty =
  CCFormat.sprintf "@[<h>@@%a@]" (pp_gty ~decode) gty

let get_ty_witness ~decode gty =
  try GTy_map.find gty decode.witnesses
  with Not_found ->
    errorf_ "no witness declared for cardinality bound on %a" (pp_gty ~decode)
      gty

(* print processed problem *)
let pp_problem out (decode, pb) =
  (* print ID and remember its name for parsing model afterward *)
  let rec pp_id out id =
    (* find a unique name for this ID *)
    let name = id_to_name ~decode id in
    CCFormat.string out name
  (* print [is-c] for a constructor [c] *)
  and pp_tester out c =
    let name = Printf.sprintf "is-%s" (id_to_name ~decode c) in
    Hashtbl.replace decode.name_to_id name (DataTest c);
    CCFormat.string out name
  (* print [select-c-n] to select the n-th argument of [c] *)
  and pp_select out (c, n) =
    let name = Printf.sprintf "_select_%s_%d" (id_to_name ~decode c) n in
    Hashtbl.replace decode.name_to_id name (DataSelect (c, n));
    CCFormat.string out name
  (* print type (a monomorphic type) in SMT.  This is the declaration the
     domain parser later compares a reply against, so it is that same
     description rather than a second copy of it. *)
  and pp_ty out ty = Sexp_lib.pp out (sexp_of_gty_decl ~decode ty)
  (* print type in SMT syntax *)
  and pp_ty_decl out ty =
    let args, ret = ty in
    fpf out "%a %a" (CCFormat.within "(" ")" (pp_list pp_ty)) args pp_ty ret
  and pp_term out t =
    match T.view t with
    | FO.Builtin b -> ( match b with `Int n -> CCFormat.int out n)
    | FO.Var v -> Var.pp_full out v
    | FO.App (f, []) -> pp_id out f
    | FO.App (f, l) -> fpf out "(@[%a@ %a@])" pp_id f (pp_list pp_term) l
    | FO.DataTest (c, t) -> fpf out "(@[%a@ %a@])" pp_tester c pp_term t
    | FO.DataSelect (c, n, t) ->
        fpf out "(@[%a@ %a@])" pp_select (c, n) pp_term t
    | FO.Undefined t -> pp_term out t (* tailcall, probably *)
    | FO.Undefined_atom _ -> errorf_ "cannot print `undefined_atom` in SMTlib"
    | FO.Unparsable _ -> errorf_ "cannot print `unparsable` in SMTlib"
    | FO.Card_at_least (_, n) when n <= 1 -> fpf out "true" (* trivial *)
    | FO.Card_at_least (ty, n) ->
        let witness = get_ty_witness ~decode ty in
        fpf out "(@[(not (_ fmf.card %a %d))@])" pp_id witness (n - 1)
    | FO.Fun (v, t) ->
        fpf out "@[<3>(LAMBDA@ ((%a %a))@ %a)@]" Var.pp_full v pp_ty (Var.ty v)
          pp_term t
    | FO.Let (v, t, u) ->
        fpf out "@[<3>(let@ ((%a %a))@ %a@])" Var.pp_full v pp_term t pp_term u
    | FO.Mu _ -> Utils.not_implemented "cannot send MU-term to CVC4"
    | FO.Ite (a, b, c) ->
        fpf out "@[<2>(ite@ %a@ %a@ %a)@]" pp_term a pp_term b pp_term c
    | FO.True -> CCFormat.string out "true"
    | FO.False -> CCFormat.string out "false"
    | FO.Eq (a, b) -> fpf out "(@[=@ %a@ %a@])" pp_term a pp_term b
    | FO.And [] -> CCFormat.string out "true"
    | FO.And [ f ] -> pp_term out f
    | FO.And l -> fpf out "(@[and@ %a@])" (pp_list pp_term) l
    | FO.Or [] -> CCFormat.string out "false"
    | FO.Or [ f ] -> pp_term out f
    | FO.Or l -> fpf out "(@[or@ %a@])" (pp_list pp_term) l
    | FO.Not f -> fpf out "(@[not@ %a@])" pp_term f
    | FO.Imply (a, b) -> fpf out "(@[=>@ %a@ %a@])" pp_term a pp_term b
    | FO.Equiv (a, b) -> fpf out "(@[=@ %a@ %a@])" pp_term a pp_term b
    | FO.Forall (v, f) ->
        fpf out "(@[<2>forall@ ((%a %a))@ %a@])" Var.pp_full v pp_ty (Var.ty v)
          pp_term f
    | FO.Exists (v, f) ->
        fpf out "(@[<2>exists@ ((%a %a))@ %a@])" Var.pp_full v pp_ty (Var.ty v)
          pp_term f
  and pp_statement out = function
    | FO.TyAlias (id, ty, _) ->
        fpf out "(@[define-sort@ %a@ %a@])" pp_id id pp_ty_decl ty
    | FO.TyDecl (id, arity, _) ->
        fpf out "(@[declare-sort@ %a@ %d@])" pp_id id arity
    | FO.Decl (v, ty, _) ->
        fpf out "(@[<2>declare-fun@ %a@ %a@])" pp_id v pp_ty_decl ty
    | FO.Axiom t -> fpf out "(@[assert@ %a@])" pp_term t
    | FO.Goal t -> fpf out "(@[assert@ %a@])" pp_term t
    | FO.CardBound (ty_id, which, n) -> (
        let witness = get_ty_witness ~decode (gty_const ty_id) in
        let pp_max_card out n =
          if n < 1 then fpf out "(assert false)" (* absurd *)
          else fpf out "(@[assert (_ fmf.card %a %d)@])" pp_id witness n
        and pp_min_card out n =
          if n <= 1 then ()
          else
            fpf out "(@[assert (not (_ fmf.card %a %d))@])" pp_id witness (n - 1)
        in
        match which with `Max -> pp_max_card out n | `Min -> pp_min_card out n)
    | FO.MutualTypes (k, l) -> pp_mutual_types out k l
  and pp_mutual_types out k l =
    let pp_arg out (c, i, ty) =
      fpf out "(@[<h>%a %a@])" pp_select (c, i) pp_ty ty
    in
    let pp_cstor out c =
      (* add selectors *)
      let args =
        List.mapi (fun i ty -> (c.FO.cstor_name, i, ty)) c.FO.cstor_args
      in
      fpf out "(@[<2>%a@ %a@])" pp_id c.FO.cstor_name (pp_list pp_arg) args
    in
    let n_vars = List.length l.FO.tys_vars in
    let pp_tydef out tydef =
      let cstors = ID.Map.to_list tydef.FO.ty_cstors |> List.map snd in
      if l.FO.tys_vars = [] then fpf out "(@[%a@])" (pp_list pp_cstor) cstors
      else
        fpf out "(@[par (@[%a@])@ (@[%a@])@])" (pp_list pp_id) l.FO.tys_vars
          (pp_list pp_cstor) cstors
    and pp_decl out tydef =
      fpf out "(@[%a@ %d@])" pp_id tydef.FO.ty_name n_vars
    in
    fpf out "(@[<2>%s@ (@[%a@])@ (@[<hv>%a@])@])"
      (match k with
      | `Data -> "declare-datatypes"
      | `Codata -> "declare-codatatypes")
      (pp_list pp_decl) l.FO.tys_defs (pp_list pp_tydef) l.FO.tys_defs
  in
  (* send prelude *)
  fpf out "@[<v>";
  fpf out "(set-option :produce-models true)@,";
  fpf out "(set-option :interactive-mode true)@,";
  fpf out "(set-option :finite-model-find true)@,";
  fpf out "(set-logic UFCDT)@,";
  (* write problem *)
  Utils.pp_iter ~sep:"" pp_statement out
    (CCVector.to_iter pb.FO.Problem.statements);
  fpf out "@,(check-sat)@]@.";
  ()

let send_ s problem =
  fpf s.fmt "%a@." pp_problem (s.decode, problem);
  Format.pp_print_flush s.fmt ();
  ()

(* {2 Decoding cvc5's replies}

   Everything from here to [get_model_] reads what cvc5 sent, which is
   untrusted input: it may come from a version that does not implement the
   command, or that answers in a shape we have never seen.  So a failure here
   is never [Error]/fatal -- it is [Backend_err], reported by [read_res_] as
   [U_backend_error] with the other arms left running. *)

let find_atom_ ~decode s =
  try Hashtbl.find decode.name_to_id s
  with Not_found ->
    (* introduced by cvc5 in the model; make a new ID *)
    let id = ID.make s in
    Hashtbl.replace decode.name_to_id s (ID id);
    ID id

(* parse an identifier *)
let parse_atom_ ~decode = function
  | `Atom s -> (
      match CCString.Split.right ~by:"_" s with
      | None -> find_atom_ ~decode s
      | Some (pre, n) -> (
          (* might be a De Bruijn index *)
          try
            let ty = Hashtbl.find decode.db_prefixes pre in
            let n = int_of_string n in
            De_bruijn (n, ty)
          with Not_found -> find_atom_ ~decode s))
  | _ -> cvc5_error_ "expected ID, got a list"

let parse_id_ ~decode s =
  match parse_atom_ ~decode s with
  | ID id -> id
  | De_bruijn _ | DataTest _ | DataSelect _ ->
      cvc5_error_ "expected ID, got data test/select/de bruijn"

(* parse an atomic type *)
let rec parse_ty_ ~decode = function
  | `Atom "Bool" -> Ty.builtin `Prop
  | `Atom _ as f ->
      let id = parse_id_ ~decode f in
      Ty.const id
  | `List ((`Atom _ as f) :: l) ->
      let id = parse_id_ ~decode f in
      let l = List.map (parse_ty_ ~decode) l in
      Ty.app id l
  | _ -> cvc5_error_ "invalid type"

let parse_var_ ~decode = function
  | `List [ (`Atom _ as v); ty ] ->
      let id = parse_id_ ~decode v in
      let ty = parse_ty_ ~decode ty in
      Var.of_id ~ty id
  | _ -> cvc5_error_ "expected typed variable"

let parse_int_ = function
  | `Atom n -> ( try int_of_string n with _ -> cvc5_error_ "expected int")
  | `List _ -> cvc5_error_ "expected int"

(* parse a ground term *)
let rec parse_term_ ~decode s =
  let r = ref None in
  (* maybe, a mu-variable *)
  decode.db_stack <- r :: decode.db_stack;
  let res =
    CCFun.finally
      ~h:(fun () -> decode.db_stack <- List.tl decode.db_stack)
      ~f:(fun () -> parse_term_sub_ ~decode s)
  in
  match !r with None -> res | Some v -> T.mu v res (* introduce a mu binder *)

and parse_term_sub_ ~decode = function
  | `Atom "true" -> T.true_
  | `Atom "false" -> T.false_
  | `Atom s as t -> (
      match Hashtbl.find_opt decode.let_vars s with
      | Some v -> v
      | None -> (
          match parse_atom_ ~decode t with
          | ID id -> (
              (* can be a constant or a variable, depending on scoping *)
              try T.var (ID.Tbl.find decode.vars id)
              with Not_found -> T.const id)
          | De_bruijn (n, ty) -> (
              (* adjust: the current term, i.e. the constant, doesn't have
               a binder, so its stack slot should not count *)
              let n = n + 1 in
              match CCList.get_at_idx n decode.db_stack with
              | None -> backend_errorf_ "De Bruijn index %d not bound" n
              | Some r -> (
                  match !r with
                  | Some v -> T.var v (* use same variable *)
                  | None ->
                      (* introduce new variable *)
                      let v = Var.make ~ty ~name:"self" in
                      r := Some v;
                      T.var v))
          | DataTest _ | DataSelect _ ->
              cvc5_error_ "expected ID, got data test/select"))
  | `List [ `Atom ("LAMBDA" | "lambda"); `List bindings; body ] ->
      (* lambda term *)
      let bindings = List.map (parse_var_ ~decode) bindings in
      (* enter scope of variables *)
      within_scope ~decode bindings (fun () ->
          let body = parse_term_ ~decode body in
          List.fold_right T.fun_ bindings body)
  | `List [ `Atom "ite"; a; b; c ] ->
      let a = parse_term_ ~decode a in
      let b = parse_term_ ~decode b in
      let c = parse_term_ ~decode c in
      T.ite a b c
  | `List [ `Atom "="; a; b ] ->
      let a = parse_term_ ~decode a in
      let b = parse_term_ ~decode b in
      T.eq a b
  | `List [ `Atom "not"; f ] ->
      let f = parse_term_ ~decode f in
      T.not_ f
  | `List (`Atom "and" :: l) -> T.and_ (List.map (parse_term_ ~decode) l)
  | `List (`Atom "or" :: l) -> T.or_ (List.map (parse_term_ ~decode) l)
  | `List [ `Atom "forall"; `List bindings; f ] ->
      let bindings = List.map (parse_var_ ~decode) bindings in
      within_scope ~decode bindings (fun () ->
          let f = parse_term_ ~decode f in
          List.fold_right T.forall bindings f)
  | `List [ `Atom "exists"; `List bindings; f ] ->
      let bindings = List.map (parse_var_ ~decode) bindings in
      within_scope ~decode bindings (fun () ->
          let f = parse_term_ ~decode f in
          List.fold_right T.exists bindings f)
  | `List [ `Atom "=>"; a; b ] ->
      let a = parse_term_ ~decode a in
      let b = parse_term_ ~decode b in
      T.imply a b
  | `List [ `Atom "as"; term; _sort ] ->
      (* SMT-LIB 2.7 may wrap a value `v` in `(as v s)` to make its sort `s` explicit *)
      parse_term_ ~decode term
  | `List [ `Atom "let"; `List bindings; body ] ->
      let bindings = List.map (parse_let_binding ~decode) bindings in
      within_let_scope ~decode bindings (fun () -> parse_term_ ~decode body)
  | `List ((`Atom s as f) :: l) as sexp -> (
      match Hashtbl.find_opt decode.let_vars s with
      | Some _ -> backend_errorf_ "Application of let variable %a" Sexp_lib.pp sexp
      | None -> (
          match (parse_atom_ ~decode f, l) with
          | ID f, _ ->
              (* regular function app *)
              let l = List.map (parse_term_ ~decode) l in
              T.app f l
          | De_bruijn _, _ -> cvc5_error_ "invalid arity for De Bruijn index"
          | DataTest c, [ t ] ->
              let t = parse_term_ ~decode t in
              T.data_test c t
          | DataTest _, _ -> cvc5_error_ "invalid arity for DataTest"
          | DataSelect (c, n), [ t ] ->
              let t = parse_term_ ~decode t in
              T.data_select c n t
          | DataSelect _, _ -> cvc5_error_ "invalid arity for DataSelect"))
  | `List (`List _ :: _) as s ->
      backend_errorf_ "non first-order list@ %a" Sexp_lib.pp s
  | `List [] -> cvc5_error_ "expected term, got empty list"

and within_scope ~decode bindings f =
  List.iter (fun v -> ID.Tbl.add decode.vars (Var.id v) v) bindings;
  CCFun.finally ~f ~h:(fun () ->
      List.iter (fun v -> ID.Tbl.remove decode.vars (Var.id v)) bindings)

and parse_let_binding ~decode = function
  | `List [ `Atom id; value ] -> (id, parse_term_ ~decode value)
  | s ->
      backend_errorf_ "invalid let variable declaration declaration@ %a" Sexp_lib.pp s

and within_let_scope ~decode bindings f =
  List.iter (fun (var, value) -> Hashtbl.add decode.let_vars var value) bindings;
  CCFun.finally ~f ~h:(fun () ->
      List.iter (fun (var, _) -> Hashtbl.remove decode.let_vars var) bindings)

(* parse a function with [n] arguments *)
let parse_fun_ ~decode ~arity:n ~env term =
  (* split [t] into [n]-ary function arguments and body *)
  let rec get_args t n =
    if n = 0 then ([], t)
    else
      match T.view t with
      | FO.Fun (v, t') ->
          let vars, body = get_args t' (n - 1) in
          (v :: vars, body)
      | _ -> backend_errorf_ "expected %d-ary function,@ got `@[%a@]`" n FO.pp_term t
  in
  (* parse term, then convert into [vars -> decision-tree] *)
  let t = parse_term_ ~decode term in
  let vars, body = get_args t n in
  (* change the shape of [body] so it looks more like a decision tree *)
  Utils.debugf ~section 1 "@[<2>turn term `@[%a@]`@ @]" (fun k ->
      k FO.pp_term body);
  let fdt = FO.Util.flat_dt_of_term ~vars body in
  let fdt = FO.Util.simplify_flat_dt fdt env in
  let dt = Model.DT.of_flat ~equal:T.equal ~hash:T.hash fdt in
  Utils.debug ~section 1 "END";
  Utils.debugf ~section 5 "@[<2>turn term `@[%a@]`@ into DT `@[%a@]`@]"
    (fun k -> k FO.pp_term body (Model.DT.pp FO.pp_term' FO.pp_ty) dt);
  dt

let sym_get_ty_ ~decode id =
  match ID.Tbl.find decode.symbols id with
  | Q_const | Q_fun _ -> assert false
  | Q_type ty -> ty

let get_kind ~decode id =
  try ID.Map.find id decode.kinds
  with Not_found -> errorf_ "could not find kind of %a" ID.pp id

(* state: decode_state *)
let parse_simple_model_ ~decode ~env : Sexp_lib.t -> (_, _) Model.t = function
  | `Atom _ -> cvc5_error_ "expected model, got atom"
  | `List assoc ->
      (* parse model *)
      let m =
        List.fold_left
          (fun m -> function
            | `List [ (`Atom _ as s); term ] -> (
                let id = parse_id_ ~decode s in
                (* the reply names the symbol, so neither its kind nor the
                   query it answers can be assumed to exist *)
                let kind =
                  try ID.Map.find id decode.kinds
                  with Not_found ->
                    backend_errorf_ "cvc5 gave a value for `%a`, which is not a symbol of the problem"
                      ID.pp id
                in
                match ID.Tbl.find_opt decode.symbols id with
                | Some Q_const ->
                    let t = parse_term_ ~decode term in
                    Model.add_const m (T.const id, t, kind)
                | Some (Q_fun n) ->
                    let dt = parse_fun_ ~decode ~arity:n ~env term in
                    Model.add_value m (T.const id, dt, kind)
                | Some (Q_type _) ->
                    backend_errorf_ "cvc5 gave a value for `%a`, which is a type witness"
                      ID.pp id
                | None ->
                    backend_errorf_ "cvc5 gave a value for `%a`, which we did not ask about"
                      ID.pp id)
            | s ->
                backend_errorf_ "expected a key/value pair in the model, got `%a`"
                  Sexp_lib.pp s)
          Model.empty assoc
      in
      m

(* A domain element, as cvc5 prints it in the answer to
   [get-model-domain-elements]: [(as NAME TY)], where TY is the SMT name of the
   type being enumerated.  Nothing else is a domain element -- in particular
   [(error "...")] is a two-atom list, so accepting bare atoms here would
   silently turn an error reply into a two-element domain.  TY is compared as a
   sexp, because for a compound sort cvc5 echoes a list. *)
(* An SMT symbol, simple or [|…|]-quoted -- never a string literal, which the
   lexer also hands over as an atom.  A name goes into the model and so onto
   the user's stdout; a string literal there would let the solver put arbitrary
   bytes in it. *)
let is_symbol_atom s = String.length s > 0 && s.[0] <> '"'

let parse_domain_elem_ ~decode ~gty : Sexp_lib.t -> string =
  let expected_ty = sexp_of_gty ~decode gty in
  function
  | `List [ `Atom "as"; `Atom name; ty ]
    when ty = expected_ty && is_symbol_atom name ->
      name
  | s ->
      backend_errorf_ "expected a domain element `(as <symbol> %a)`, got `%a`"
        Sexp_lib.pp expected_ty Sexp_lib.pp s

let parse_domain_elems_ ~decode ~gty : Sexp_lib.t -> string list = function
  | `Atom _ as s ->
      backend_errorf_ "expected a list of domain elements, got the atom `%a`"
        Sexp_lib.pp s
  | `List (`Atom "error" :: _ as l) ->
      backend_errorf_ "cvc5 rejected `get-model-domain-elements`: `%a`"
        Sexp_lib.pp (`List l)
  | `List [] -> backend_errorf_ "cvc5 reported an empty domain"
  | `List l ->
      (* left-to-right, so the element named in a rejection is always the first
         bad one; [List.map]'s order is unspecified *)
      let names = List.rev (List.rev_map (parse_domain_elem_ ~decode ~gty) l) in
      (* the counter this parser replaces produced distinct names for free *)
      if List.length (CCList.sort_uniq ~cmp:String.compare names)
         < List.length names
      then
        backend_errorf_ "cvc5 reported a domain with repeated elements: `%a`"
          Sexp_lib.pp (`List l);
      names

let get_finite_domain_ ~print_model decode s witness_id =
  let pp_id out i = CCFormat.string out (ID.Tbl.find decode.id_to_name i) in
  fpf s.fmt "(@[<hv2>get-model-domain-elements %a@])@." pp_id witness_id;
  match DSexp.next s.sexp with
  | `Error e -> cvc5_error_ e
  | `End -> cvc5_error_ "unexpected end of input from cvc5: expected model"
  | `Ok sexp ->
      if print_model then
        Format.eprintf "@[raw domain elements:@ @[<hv>%a@]@]@." Sexp_lib.pp sexp;
      let gty = sym_get_ty_ ~decode witness_id in
      let ty = fobackty_of_ground_ty gty in
      let names = parse_domain_elems_ ~decode ~gty sexp in
      (* Resolve a reported name without mutating [decode] first, so that a
         rejected reply leaves no stray registration behind: [find_atom_]
         installs a fresh [ID.make] for a name it has never seen, and is
         therefore reached only after the name is known to be new -- which is
         also what makes its [ID] result the only possible one. *)
      let id_of_name name =
        Utils.debugf ~section 3 "@[domain element: %s @]" (fun k -> k name);
        match Hashtbl.find_opt decode.name_to_id name with
        (* [id_to_name] holds exactly the names we declared to cvc5, so this is
           the test that matches the message: a domain element must be a name
           cvc5 invented, not one of ours.  Taking [decode.symbols] instead --
           only the symbols we asked a value for -- let a reply name the type's
           own sort, [(as a__ a__)], and pass. *)
        | Some (ID id) when ID.Tbl.mem decode.id_to_name id ->
            backend_errorf_
              "cvc5 reported `%s` as a domain element, but it is a symbol of \
               the problem"
              name
        | Some (ID id) -> id
        | Some (De_bruijn _) ->
            backend_errorf_
              "cvc5 reported `%s` as a domain element, but it is a De Bruijn \
               index"
              name
        | Some (DataTest _ | DataSelect _) ->
            backend_errorf_
              "cvc5 reported `%s` as a domain element, but it is a datatype \
               tester or selector"
              name
        | None -> (
            match find_atom_ ~decode name with ID id -> id | _ -> assert false)
      in
      (* [rev_map] reproduces the order the counting code built by [to_rev_list] *)
      let terms = List.rev_map id_of_name names in
      (ty, terms)

let send_get_simple_model_ out decode =
  (* print a single symbol *)
  let pp_id out i = CCFormat.string out (ID.Tbl.find decode.id_to_name i) in
  let pp_simple_query out (id, q) =
    match q with Q_const | Q_fun _ -> pp_id out id | Q_type _ -> assert false
  in
  fpf out "(@[<hv2>get-value@ (@[<hv>%a@])@])"
    (Utils.pp_iter ~sep:" " pp_simple_query)
    (ID.Tbl.to_iter decode.symbols
    |> Iter.filter (fun (_, q) -> is_simple_query q))

(* read model from cvc5 instance [s] *)
let get_model_ ~print_model ~decode ~env s : (_, _) Model.t =
  Utils.debugf ~section 3 "@[<2>ask for simple part of model with@ %a@]"
    (fun k -> k send_get_simple_model_ decode);
  fpf s.fmt "%a@." send_get_simple_model_ decode;
  (* read result back *)
  let simple_model =
    match DSexp.next s.sexp with
    | `Error e -> cvc5_error_ e
    | `End -> cvc5_error_ "unexpected end of input from cvc5: expected model"
    | `Ok sexp ->
        if print_model then
          Format.eprintf "@[raw model:@ @[<hv>%a@]@]@." Sexp_lib.pp sexp;
        let m = parse_simple_model_ ~decode ~env sexp in
        m
  in
  let m =
    Iter.(
      ID.Tbl.to_iter decode.symbols
      |> filter (fun (_, q) -> is_card_query q)
      |> map (fun (id, _) -> get_finite_domain_ ~print_model decode s id)
      |> fold
           (fun m (ty, terms) -> Model.add_finite_type m ty terms)
           simple_model)
  in
  (* check all symbols are defined *)
  let ok =
    List.length m.Model.values + List.length m.Model.finite_types
    = ID.Tbl.length decode.symbols
  in
  if not ok then cvc5_error_ "some symbols are not defined in the model";
  m

(* read the result *)
let read_res_ ~info ~print_model ~decode ~env s =
  try
    match DSexp.next s.sexp with
    | `Ok (`Atom "unsat") ->
        Utils.debug ~section 5 "cvc5 returned `unsat`";
        Res.Unsat (Lazy.force info)
    | `Ok (`Atom "sat") ->
        Utils.debug ~section 5 "cvc5 returned `sat`";
        let m =
          if ID.Tbl.length decode.symbols = 0 then Model.empty
          else get_model_ ~print_model ~decode ~env s
        in
        Res.Sat (m, Lazy.force info)
    | `Ok (`Atom "unknown") ->
        Utils.debug ~section 5 "cvc5 returned `unknown`";
        Res.Unknown [ Res.U_other (Lazy.force info, "") ]
    | `Ok (`List [ `Atom "error"; `Atom s ]) ->
        (* the message reaches the user verbatim, so show it unquoted *)
        let s = Sexp_lib.unquote_atom s in
        Utils.debugf ~section 5 "@[<2>cvc5 returned `error %s`@]" (fun k -> k s);
        Res.Unknown [ Res.U_backend_error (Lazy.force info, cvc5_error_ s) ]
    | `Ok sexp ->
        let msg =
          CCFormat.sprintf "@[unexpected answer from cvc5:@ `%a`@]" Sexp_lib.pp
            sexp
        in
        Res.Unknown [ Res.U_backend_error (Lazy.force info, msg) ]
    (* a reply we cannot even tokenise is still the solver's doing, not ours *)
    | `Error e -> Res.Unknown [ Res.U_backend_error (Lazy.force info, e) ]
    | `End ->
        Utils.debug ~section 5 "no answer from cvc5, assume it timeouted";
        Res.Unknown [ Res.U_timeout (Lazy.force info) ]
  with
  | Backend_err msg -> Res.Unknown [ Res.U_backend_error (Lazy.force info, msg) ]
  | (Sys.Break | Out_of_memory) as e -> raise e
  | e ->
      (* Reaching here means the decoder failed without naming a cause -- a gap
         in it, not a verdict.  A reply is untrusted input either way, so it is
         reported like any other unusable one and the warning says which
         exception it was; aborting the run over it would cost the sibling
         backends their answers for a defect of ours. *)
      let msg = Printexc.to_string e in
      Utils.warningf Utils.Warn_model_parsing_error
        "@[<2>could not decode cvc5's reply:@ %s@]" msg;
      Res.Unknown [ Res.U_backend_error (Lazy.force info, msg) ]

(* the set of options given to every instance of cvc5 *)
let basic_options =
  "--lang smt --finite-model-find"

let mk_info ~options (decode : decode_state) : Res.info =
  let time = Utils.Time.get_timer decode.timer in
  let message = Printf.sprintf "options: `%s %s`" basic_options options in
  Res.mk_info ~backend:"cvc5" ~time ~message ()

let res ~env t =
  match t.res with
  | Some r -> r
  | None when t.closed ->
      let r =
        Res.Unknown [ Res.U_timeout (mk_info ~options:t.options t.decode) ]
      in
      t.res <- Some r;
      r
  | None ->
      let info = lazy (mk_info ~options:t.options t.decode) in
      let r =
        try read_res_ ~info ~print_model:t.print_model ~decode:t.decode ~env t
        with e -> Res.Error (e, Lazy.force info)
      in
      t.res <- Some r;
      r

(* once processed, the problem also contains the set of symbols to
   read back from the model, and type witnesses *)
type processed_problem = decode_state * problem

(* is [ty] a finite (uninterpreted) type? *)
let is_finite_ decode ty =
  match Ty.view ty with
  | FO.TyApp (id, _) -> get_kind ~decode id = Model.Symbol_utype
  | _ -> false

(* does two things:
    - add some witness alias sorts for uninterpreted types (for asking for
        the type's domain later)
    - compute the set of symbols for which we want the model's value *)
let preprocess pb : processed_problem =
  let kinds = FO.Util.problem_kinds pb in
  let n = ref 0 in
  let state = create_decode_state ~kinds () in
  let decl state id c = ID.Tbl.add state.symbols id c in
  let add_db_prefix state c ty = Hashtbl.replace state.db_prefixes c ty in
  (* if some types in [l] do not have a witness, add them to [[stmt]] *)
  let add_ty_witnesses stmt l =
    List.fold_left
      (fun acc gty ->
        if (not (is_finite_ state gty)) || GTy_map.mem gty state.witnesses then
          acc
          (* already declared a witness for [gty], or [gty] is not
                     a finite type *)
        else
          (* add a dummy constant *)
          let c = ID.make (CCFormat.sprintf "__nun_card_witness_%d" !n) in
          incr n;
          (* declare [c] *)
          let ty_c = ([], gty) in
          decl state c (Q_type gty);
          state.witnesses <- GTy_map.add gty c state.witnesses;
          FO.TyAlias (c, ty_c, []) :: acc)
      [ stmt ] l
    |> List.rev
  in
  (* gather list of (possibly parametrized) types occurring in [stmt],
     add witnesses for them *)
  let add_ty_witnesses_gen stmt =
    let tys =
      FO.tys_of_statement stmt
      |> Iter.flat_map FO.Ty.to_iter
      |> Iter.sort_uniq ~cmp:FO.Ty.compare
      |> Iter.to_rev_list
    in
    add_ty_witnesses stmt tys
  in
  let pb =
    FO.Problem.flat_map ~meta:(FO.Problem.meta pb)
      (fun stmt ->
        match stmt with
        | FO.TyAlias (_, _, _) -> assert false
        | FO.Decl (id, (args, _), _) ->
            let len = List.length args in
            if len = 0 then decl state id Q_const else decl state id (Q_fun len);
            (* if args contains composite types, add witnesses for them *)
            add_ty_witnesses stmt args
        | FO.CardBound (id, _, _) | FO.TyDecl (id, 0, _) ->
            add_ty_witnesses stmt [ gty_const id ]
        | FO.MutualTypes (`Codata, l) ->
            List.iter
              (fun tydef ->
                (* use De Bruijn prefixes *)
                let ty = gty_const tydef.FO.ty_name in
                let c = const_of_ty ~decode:state ty in
                Utils.debugf ~section 5
                  "@[<2>declare `%s` as De Bruijn prefix@]" (fun k -> k c);
                add_db_prefix state c ty)
              l.FO.tys_defs;
            add_ty_witnesses_gen stmt
        | FO.TyDecl _ (* witnesses will be added on demand *) | FO.Axiom _
        | FO.Goal _
        | FO.MutualTypes (_, _) ->
            add_ty_witnesses_gen stmt)
      pb
  in
  (state, pb)

(* the cvc5 binary: $NUNCHAKU_CVC5 (a path) overrides PATH lookup *)
let cvc5_program_ () =
  Utils.external_program ~env_var:"NUNCHAKU_CVC5" ~default:"cvc5"

(* the command line to invoke cvc5 *)
let mk_cvc5_cmd_ timeout options =
  let timeout_hard = int_of_float (timeout +. 1.50001) in
  let timeout_ms = int_of_float (timeout *. 1000.) in
  Printf.sprintf "ulimit -t %d; exec %s --tlimit=%d %s %s" timeout_hard
    (Filename.quote (cvc5_program_ ())) timeout_ms basic_options options

let solve ?(options = "") ?deadline ?(print = false) ?(print_model = false) ~env pb =
  let now = Unix.gettimeofday () in
  let deadline = match deadline with Some s -> s | None -> now +. 30. in
  (* preprocess first *)
  let decode, problem' = preprocess pb in
  if print then
    Format.printf "@[<v2>SMT problem:@ %a@]@." pp_problem (decode, problem');
  (* enough time remaining? *)
  if now +. 0.1 > deadline then
    let message = Printf.sprintf "options: `%s`" options in
    let info = Res.mk_info ~backend:"cvc5" ~time:0. ~message () in
    S.Fut.return (Res.Unknown [ Res.U_timeout info ], S.No_shortcut)
  else (
    Utils.debug ~section 1 "calling cvc5";
    let timeout = deadline -. now in
    assert (timeout > 0.);
    let cmd = mk_cvc5_cmd_ timeout options in
    S.popen cmd ~f:(fun (oc, ic) ->
        let s = create_ ~options ~print_model ~decode (ic, oc) in
        send_ s problem';
        let r = res ~env s in
        Utils.debugf ~lock:true ~section 3 "@[<2>result: %a@]" (fun k ->
            k (Res.pp FO.pp_term' FO.pp_ty) r);
        close s;
        match r with
        | Res.Sat (_, _) -> (r, S.Shortcut)
        | Res.Unsat i -> (Res.Unsat i, S.Shortcut)
        | Res.Unknown _ -> (r, S.No_shortcut)
        (* A cvc5 defect costs cvc5 this arm, and not the run.  Ending the race
           here would stop smbc and the other four arms, so an answer one of
           them was about to give is lost to a fault in this one -- the
           argument [Smbc.parse_res] already makes for the other backend, and
           §18's for the scheduler.  Reported as an [Unknown] carrying the
           error rather than as [Res.Error] because that is the same decision,
           not a second one: [Close_task] and [process_res_] reject by name a
           non-[Unknown] result that did not end the race.  The command line
           stays in the debug line and out of the reported reason, which the
           caller sees. *)
        | Res.Error (e, info) ->
            Utils.debugf ~lock:true ~section 1
              "@[<2>error while running cvc5@ with `%s`:@ @[%s@]@]" (fun k ->
                k cmd (Printexc.to_string e));
            let msg =
              Printf.sprintf "error while running cvc5: %s"
                (Printexc.to_string e)
            in
            (Res.Unknown [ Res.U_backend_error (info, msg) ], S.No_shortcut))
    |> S.Fut.map (function
         | E.Ok x -> fst x
         (* an exception escaping the whole exchange with cvc5: same reasoning
            as above, same shape *)
         | E.Error e ->
             let info = mk_info ~options decode in
             let msg =
               Printf.sprintf "error while running cvc5: %s"
                 (Printexc.to_string e)
             in
             (Res.Unknown [ Res.U_backend_error (info, msg) ], S.No_shortcut)))

let is_available () =
  let res = Utils.external_program_available (cvc5_program_ ()) in
  if res then Utils.debug ~section 3 "cvc5 is available";
  res

(* The ORDER of this list is load-bearing.  It reads like a set of techniques
   to try; the scheduler treats it as a priority queue that it then starves.

   - [pipes] below gives arm [i] priority [30 + 10*i], and smbc asks for 20
     ([Smbc.ml]), so the pool runs smbc and the lowest-numbered arms first.
   - The pool starts only [-j] tasks at once and the Isabelle frontend never
     passes [-j], so at the default 3 exactly smbc and arms 1 and 2 are
     running at t = 0.  A third arm starts when a slot frees; on the captured
     benchmark that is usually smbc dying at t = 0 on its own assertion.
   - So appending an arm here adds one that may never start, and inserting one
     demotes every arm below it by a place.  That is a change of behaviour for
     arms whose text was not touched.

   What that costs, measured on the captured Isabelle benchmark: every answer
   to goal p034 is produced by [--macros-quant --macros-quant-mode=all], and
   moving it from position 3 to position 4 loses the goal outright -- 0 of 30,
   0 of 95 and 0 of 4 runs in three independent sessions, against 1 of 30,
   37 of 95 and 1 of 4 with the shipped order.  The opposite mistake is just
   as easy: arm 5 has never won a race in 5 x 79 x 4 runs, and it is
   nonetheless p034's *fastest* solver at 133-268 ms.  It never wins because
   it never starts.  Win-rate is not coverage, and this list must not be
   pruned on win-rate data from a scheduler that starves most of it. *)
let options_l =
  [
    "--fmf-mbqi=none";
    "--decision=internal";
    "--macros-quant --macros-quant-mode=all";
    "--e-matching";
    "--mbqi --fmf-mbqi=none";
  ]

(* One arm's deadline is the cvc5 slice over this.  A constant, and not
   [List.length options], on purpose: with the length in it, editing
   [options_l] silently re-tuned every arm's deadline as well as re-ordering
   the arms, so one edit was three effects and no measurement could say which
   one it had seen.  It is [List.length options_l] today; keeping the two in
   step is a deliberate edit, which is the point. *)
let arm_slice_divisor_ = 5

(* solve problem using cvc5 before [deadline] *)
let call ?(options = "") ?prio ?slice ~print ~dump ~print_smt ~print_model ~env
    problem =
  if print then Format.printf "@[<v2>FO problem:@ %a@]@." FO.pp_problem problem;
  match dump with
  | None ->
      Scheduling.Task.of_fut ?prio ?slice (fun ~deadline () ->
          solve ~options ~deadline ~print:print_smt ~print_model ~env problem)
  | Some file ->
      let file = file ^ ".cvc5.smt2" in
      Utils.debugf ~section 1 "output cvc5 problem into `%s`" (fun k -> k file);
      let info =
        CCIO.with_out file (fun oc ->
            let out = Format.formatter_of_out_channel oc in
            let decode, problem' = preprocess problem in
            Format.fprintf out "@[<v>; generated by Nunchaku@ %a@]@." pp_problem
              (decode, problem');
            mk_info ~options decode)
      in
      S.Task.return (Res.Unknown [ Res.U_other (info, "--dump") ]) S.No_shortcut

let pipes ?(options = [ "" ]) ?slice ?(schedule_options = true) ~print ~dump
    ~print_smt ~print_model () =
  let slice =
    if schedule_options then (
      assert (options <> []);
      CCOption.map (fun s -> s /. float arm_slice_divisor_) slice)
    else slice
  in
  let encode pb =
    let env = FO.Problem.env pb in
    ( List.mapi
        (fun i options ->
          (* only print for the first task *)
          let print = print && i = 0 in
          let print_smt = print_smt && i = 0 in
          (* an arm's position in [options_l] decides whether it runs at all;
             the note there says why *)
          let prio = 30 + (10 * i) in
          call ?slice ~options ~prio ~print ~dump ~print_smt ~print_model ~env pb)
        options,
      () )
  in
  let input_spec =
    Transform.Features.(
      of_list [ (Ty, Mono); (Eqn, Absent); (Copy, Absent); (Match, Absent) ])
  in
  Transform.make ~input_spec ~name ~encode ~decode:(fun _ x -> x) ()
