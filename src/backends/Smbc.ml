
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Backend for SMBC} *)

open Nunchaku_core
open Nunchaku_parsers

module TI = TermInner
module T = Term
module A = Tip_ast
module Res = Problem.Res
module E = CCResult
module S = Scheduling
module Stmt = Statement
module PStmt = Statement.Print(T)(T)

type term = Term.t
type ty = term
type problem = (term,ty) Problem.t
type env = (term,ty) Env.t

let name = "smbc"
let section = Utils.Section.make name

(* the smbc binary: $NUNCHAKU_SMBC (a path) overrides PATH lookup *)
let smbc_program_ () =
  Utils.external_program ~env_var:"NUNCHAKU_SMBC" ~default:"smbc"

let is_available () =
  let res = Utils.external_program_available (smbc_program_ ()) in
  if res then Utils.debug ~section 3 "smbc is available";
  res

exception Out_of_scope of string
exception Conversion_error of T.t
exception Parse_result_error of string

let () = Printexc.register_printer
    (function
      | Out_of_scope msg -> Some (Printf.sprintf "problem is out of scope for SMBC: %s" msg)
      | Conversion_error t ->
        Some (Utils.err_sprintf "problem could not be converted to TIP: %a" T.pp t)
      | Parse_result_error msg -> Some ("could not parse result: " ^ msg)
      | _ -> None)

let out_of_scope msg = raise (Out_of_scope msg)
let out_of_scopef msg = Utils.exn_ksprintf msg ~f:out_of_scope


let erase = ID.Erase.create_state ()
let id_to_string =
  let escape_ _id name = match name with
    | "distinct" | "match" | "case" -> name ^ "_"
    | _ -> name
  in
  ID.Erase.to_name erase ~encode:escape_
let id_of_string s = try Some (ID.Erase.of_name erase s) with Not_found -> None

(** {2 Local Transformation}

    We perform a few local transformations.
    In particular, we replace data testers by named functions, and
    give an explicit name to selectors *)

module ID_int_tbl = CCHashtbl.Make(struct
    type t = ID.t * int
    let equal (a,i)(b,j) = ID.equal a b && i=j
    let hash (a,i) = Hashtbl.hash (ID.hash a,i)
  end)

type state = {
  local_statements: A.statement CCVector.vector;
  data_select_tbl: ID.t ID_int_tbl.t;
  data_test_tbl: ID.t ID.Tbl.t;
  env: env;
}

let mk_state (env:env): state = {
  env;
  local_statements=CCVector.create();
  data_select_tbl = ID_int_tbl.create 16;
  data_test_tbl = ID.Tbl.create 16;
}

(* remove and return the new statements *)
let local_statements (st:state): A.statement list =
  let l = CCVector.to_list st.local_statements in
  CCVector.clear st.local_statements;
  l

(** {2 Printing to SMBC} *)

let data_select_fun st c i : ID.t =
  match ID_int_tbl.get st.data_select_tbl (c,i) with
    | Some id -> id
    | None ->
      Utils.failwithf
        "cannot find TIP id for data select `select-%a-%d`" ID.pp_full c i

let rec term_to_tip (st:state) (t:term): A.term =
  let loc = Location.internal in
  match T.repr t with
  | TI.Const id -> A.const ~loc (id_to_string id)
  | TI.Var v -> A.const ~loc (conv_var v)
  | TI.App (f, l) ->
    let l = List.map (term_to_tip st) l in
    begin match T.repr f with
      | TI.Const id -> A.app ~loc (id_to_string id) l
      | TI.Builtin (`DataTest c) ->
        A.app ~loc (data_test_fun st c |> id_to_string) l
      | TI.Builtin (`DataSelect (c,i)) ->
        A.app ~loc (data_select_fun st c i |> id_to_string) l
      | _ -> List.fold_left (A.ho_app~loc) (term_to_tip st f) l
    end
  | TI.Builtin b ->
    begin match b with
      | `True -> A.true_ ~loc
      | `False -> A.false_ ~loc
      | `Or l -> A.or_ ~loc (List.map (term_to_tip st) l)
      | `And l -> A.and_ ~loc (List.map (term_to_tip st) l)
      | `Imply (a,b) -> A.imply ~loc (term_to_tip st a)(term_to_tip st b)
      | `Ite (a,b,c) -> A.if_ ~loc (term_to_tip st a)(term_to_tip st b)(term_to_tip st c)
      | `Eq (a,b) -> A.eq ~loc (term_to_tip st a)(term_to_tip st b)
      | `Not a -> A.not_ ~loc (term_to_tip st a)
      | `DataTest c -> A.const ~loc (data_test_fun st c |> id_to_string)
      | `DataSelect (c,i) -> A.const ~loc (data_select_fun st c i |> id_to_string)
      | `Undefined_atom _
      | `Undefined_self _ -> raise (Conversion_error t)
      | `Guard (t,g) ->
        (* use builtin "asserting" *)
        let t = term_to_tip st t in
        let g = T.and_nodup g.Builtin.asserting |> term_to_tip st in
        A.app ~loc "asserting" [t; g]
      | `Card_at_least (ty,n) ->
        (* encode on the fly *)
        let module CE = Cardinal_encode.Make(T) in
        let ax = CE.encode_min_card ty n in
        term_to_tip st ax
      | `Unparsable _
        -> assert false (* TODO: better error: should not happen *)
    end
  | TI.Bind (Binder.Fun,v,body) ->
    A.fun_ ~loc (conv_typed_var v) (term_to_tip  st body)
  | TI.Bind (Binder.Forall,v,body) ->
    A.forall ~loc [conv_typed_var v] (term_to_tip st body)
  | TI.Bind (Binder.Exists,v,body) ->
    A.exists ~loc [conv_typed_var v] (term_to_tip st body)
  | TI.Bind (Binder.TyForall,_,_)
  | TI.Bind (Binder.Mu,_,_) -> out_of_scopef "cannot convert to TIP µ %a" T.pp t
  | TI.Let (v,t,u) ->
    A.let_ ~loc [conv_var v, term_to_tip st t] (term_to_tip st u)
  | TI.Match (u,map,def) ->
    let u = term_to_tip st u in
    let cases =
      ID.Map.to_list map
      |> List.map
        (fun (c, (_tys,vars,rhs)) ->
           A.Match_case
             (id_to_string c, List.map conv_var vars, term_to_tip st rhs))
    and def = match def with
      | None -> []
      | Some (rhs,_) -> [A.Match_default (term_to_tip st rhs)]
    in
    A.match_ ~loc u (cases @ def)
  | TI.TyBuiltin _
  | TI.TyArrow _
  | TI.TyMeta _ -> raise (Conversion_error t)

and ty_to_tip(t:term): A.ty =
  let loc = Location.internal in
  match T.repr t with
  | TI.Const id -> A.ty_const ~loc (id_to_string id)
  | TI.Var v -> A.ty_const ~loc (conv_var v)
  | TI.App (f, l) ->
    let l = List.map ty_to_tip l in
    begin match T.repr f with
      | TI.Const id -> A.ty_app ~loc (id_to_string id) l
      | _ -> out_of_scopef "cannot convert to TIP ty %a" T.pp t
    end
  | TI.TyArrow (a,b) -> A.ty_arrow ~loc (ty_to_tip a)(ty_to_tip b)
  | TI.TyBuiltin `Prop -> A.ty_bool ~loc
  | TI.TyBuiltin `Type -> out_of_scope "cannot encode to TIP TType"
  | _ -> assert false

and conv_typed_var v = conv_var v, ty_to_tip (Var.ty v)
and conv_tyvar v = assert (T.ty_is_Type (Var.ty v)); conv_var v
and conv_var v = id_to_string (Var.id v)

(* a local function for "is-c" data tester *)
and data_test_fun (st:state) (c:ID.t): ID.t =
  let ty_c = Env.find_ty_exn ~env:st.env c in
  let ty_args, c_args, data_ty = T.ty_unfold ty_c in
  assert (ty_args = []); (* mono *)
  try ID.Tbl.find st.data_test_tbl c
  with Not_found ->
    let loc = Location.internal in
    let id = ID.make_f "is-%s" (ID.to_string_slug c) in
    (* define id *)
    let x = "x" in
    let decl = {
      A.fun_ty_vars = []; fun_loc=loc;
      fun_name = id_to_string id;
      fun_args = [x, ty_to_tip data_ty];
      fun_ret = A.ty_bool ~loc;
    } in
    (* [match x with c _ -> true | default -> false] *)
    let body =
      let c_vars = List.mapi (fun i _ -> "x_" ^ string_of_int i) c_args in
      A.match_ ~loc (A.const ~loc x)
        [ A.Match_case (id_to_string c, c_vars, A.true_ ~loc);
          A.Match_default (A.false_ ~loc);
        ]
    in
    let def = A.fun_def ~loc {A.fr_decl=decl; fr_body=body} in
    (* save and declare *)
    Utils.debugf ~section 3 "@[<2>define `is-%a` as@ `@[%a@]`@]"
      (fun k->k ID.pp_full c A.pp_stmt def);
    CCVector.push st.local_statements def;
    ID.Tbl.add st.data_test_tbl c id;
    id

let decl_to_tip id ty : A.statement =
  let loc = Location.internal in
  let s = id_to_string id in
  let ty_vars, ty_args, ty_ret = T.ty_unfold ty in
  if T.ty_is_Type ty_ret then (
    assert (ty_vars=[]);
    assert (List.for_all T.ty_is_Type ty_args);
    A.decl_sort ~loc s ~arity:(List.length ty_args)
  ) else (
    A.decl_fun s
      ~loc ~ty_vars:(List.map conv_tyvar ty_vars)
      (List.map ty_to_tip ty_args)
      (ty_to_tip ty_ret)
  )

let decl_attrs_to_tip state (id:ID.t) attrs: A.statement list =
  let loc = Location.internal in
  CCList.filter_map
    (function
      | Stmt.Attr_card_max n ->
        let module CE = Cardinal_encode.Make(T) in
        let ax = CE.encode_max_card (T.ty_const id) n |> term_to_tip state in
        Some (A.assert_ ~loc ax)
      | Stmt.Attr_card_min n ->
        let module CE = Cardinal_encode.Make(T) in
        let ax = CE.encode_min_card (T.ty_const id) n |> term_to_tip state in
        Some (A.assert_ ~loc ax)
      | _ -> None)
    attrs

let statement_to_tip (state:state) (st:(term,ty)Stmt.t): A.statement list =
  let loc = Location.internal in
  let new_st = match Stmt.view st with
    | Stmt.Decl {Stmt.defined_head=id; defined_ty=ty; defined_attrs=attrs; } ->
      let vars, _, _ = T.ty_unfold ty in
      if vars=[]
      then decl_to_tip id ty :: decl_attrs_to_tip state id attrs
      else out_of_scopef "cannot encode to TIP poly statement %a" PStmt.pp st
    | Stmt.Axiom (Stmt.Axiom_std l) ->
      List.map (fun ax -> A.assert_ ~loc (term_to_tip state ax)) l
    | Stmt.Axiom (Stmt.Axiom_spec s) ->
      (* TODO: if some variables have type {fun,datatype}, then raise Out_of_scope,
         for SMBC will not be able to handle them *)
      (* first declare, then axiomatize *)
      assert (s.Stmt.spec_ty_vars=[]);
      let decls =
        Stmt.defined_of_spec s
        |> Iter.map
          (fun {Stmt.defined_head=id; defined_ty=ty; _} ->
             decl_to_tip id ty)
        |> Iter.to_list
      and axioms =
        s.Stmt.spec_axioms
        |> List.map
          (fun t -> A.assert_ ~loc (term_to_tip state t))
      in
      decls @ axioms
    | Stmt.Axiom (Stmt.Axiom_rec l) ->
      let l =
        List.map
          (fun def ->
             if def.Stmt.rec_ty_vars <> [] then (
               out_of_scopef "polymorphic `@[%a@]`" PStmt.pp st;
             );
             let {Stmt.defined_head=id; defined_ty=ty; _} = def.Stmt.rec_defined in
             let name = id_to_string id in
             let _, _, ty_ret = T.ty_unfold ty in
             let vars, body = match def.Stmt.rec_eqns with
               | Stmt.Eqn_single (vars, rhs) ->
                 List.map conv_typed_var vars, term_to_tip state rhs
               | Stmt.Eqn_nested _ | Stmt.Eqn_app _ -> assert false
             in
             {A.
               fun_ty_vars=[]; fun_loc=loc;
               fun_name=name;
               fun_ret=ty_to_tip ty_ret;
               fun_args=vars;
             }, body)
          l
      in
      begin match l with
        | [decl,body] ->
          [A.fun_rec ~loc {A.fr_decl=decl; fr_body=body}]
        | l ->
          let decls, bodies = List.split l in
          [A.funs_rec ~loc decls bodies]
      end
    | Stmt.Goal g ->
      let neg_g = term_to_tip state (T.not_ g) in
      [A.assert_not ~loc ~ty_vars:[] neg_g]
    | Stmt.TyDef (`Codata,_) -> out_of_scopef "cannot encode Codata %a" PStmt.pp st
    | Stmt.TyDef (`Data, l) ->
      (* declare datatypes, along with their selectors *)
      let l =
        List.map
          (fun d ->
             assert (d.Stmt.ty_vars=[]);
             let name = id_to_string d.Stmt.ty_id in
             let cstors =
               ID.Map.values d.Stmt.ty_cstors
               |> Iter.map
                 (fun c ->
                    let cstor_name = id_to_string c.Stmt.cstor_name in
                    let cstor_args =
                      c.Stmt.cstor_args
                      |> List.mapi
                        (fun i ty ->
                           let id_select =
                             ID.make_f "select-%s-%d" cstor_name i
                           in
                           ID_int_tbl.add state.data_select_tbl
                             (c.Stmt.cstor_name,i) id_select;
                           id_to_string id_select, ty_to_tip ty)
                    in
                    {A.cstor_name; cstor_args})
               |> Iter.to_list
             in
             name, cstors)
          l
      in
      [A.data ~loc [] l]
    | Stmt.Pred (_,_,_)
    | Stmt.Copy _ -> assert false
  in
  local_statements state @ new_st

(* print a problem as TIP *)
let pp_pb out (pb:problem): unit =
  let env = Problem.env pb in
  let state = mk_state env in
  Problem.statements pb
  |> CCVector.iter
    (fun st ->
       let l = statement_to_tip state st in
       List.iter (Format.fprintf out "%a@." A.pp_stmt) l);
  Format.fprintf out "(check-sat)@.";
  ()

(** {2 Parsing Model}

    The model parser treats smbc's output as untrusted input: it reports,
    it never asserts. *)

let error_parse_model msg = raise (Parse_result_error msg)
let error_parse_modelf msg = Utils.exn_ksprintf ~f:error_parse_model msg

(* Failures of reading smbc's model, as opposed to failures of our own
   encoding: the model is untrusted input, so these are contained one entry
   at a time (see {!convert_model}).  [Out_of_scope] and [Conversion_error]
   are about the problem we sent and stay fatal. *)
let is_model_conversion_error = function
  | Parse_result_error _
  | TI.Undefined _ (* an id the model uses and the environment does not know *)
  | Env.UndefinedID _
  | T.No_head _
  | T.ApplyError _ -> true
  | _ -> false

module StrMap = CCMap.Make(String)
module StrTbl = CCHashtbl.Make(CCString)

(* local mapping/typing env for variables *)
type parse_env = [`Var of ty Var.t | `Subst of term] StrMap.t

let empty_penv : parse_env = StrMap.empty

(* State of one model parse, created by {!convert_model} and threaded from
   there.  Never module-level: {!erase} is, and is never reset, so a second
   problem in the same process would inherit the first one's unknowns.

   [uf_*] is the typed-unknown environment: a union-find over the ids of
   smbc's unknowns, where each class root carries at most one type and a
   poison flag.  It answers "is this unknown's type determined anywhere in
   the model?", which is a property of the model rather than of any
   enumeration of syntactic positions. *)
type parse_state = {
  unknowns: ID.t StrTbl.t; (* smbc unknown name ("?a__2") -> its id *)
  uf_parent: ID.t ID.Tbl.t; (* union-find over unknowns that must share a type *)
  uf_ty: ty ID.Tbl.t; (* at most one type per class root *)
  uf_poison: unit ID.Tbl.t; (* class roots whose type came out inconsistent *)
}

let mk_parse_state (): parse_state = {
  unknowns = StrTbl.create 16;
  uf_parent = ID.Tbl.create 16;
  uf_ty = ID.Tbl.create 16;
  uf_poison = ID.Tbl.create 8;
}

let rec uf_find (st:parse_state) (id:ID.t): ID.t =
  match ID.Tbl.get st.uf_parent id with
    | None -> id
    | Some p -> let r = uf_find st p in ID.Tbl.replace st.uf_parent id r; r

let is_poisoned (st:parse_state) (id:ID.t): bool =
  ID.Tbl.mem st.uf_poison (uf_find st id)

(* "this unknown has type [ty]".  Two incompatible types for one class mean
   no single identity is safe for it: poison the class, and warn once (the
   poison flag is what makes it once).  The warning names the unknown as
   smbc named it -- "?__<n>" is a process-global counter, useless to a
   reader of smbc's output. *)
let set_type (st:parse_state) (id:ID.t) (ty:ty): unit =
  let r = uf_find st id in
  if not (ID.Tbl.mem st.uf_poison r) then (
    match ID.Tbl.get st.uf_ty r with
      | Some ty0 when not (T.equal ty0 ty) ->
        Utils.warningf Utils.Warn_model_parsing_error
          "unknown `%a` recovered at two types: `@[%a@]` and `@[%a@]`"
          ID.pp id T.pp ty0 T.pp ty;
        ID.Tbl.replace st.uf_poison r ()
      | Some _ -> ()
      | None -> ID.Tbl.add st.uf_ty r ty
  )

(* "these two unknowns share a type, whatever it turns out to be".
   The union carries both the class type and the poison flag. *)
let same_type (st:parse_state) (a:ID.t) (b:ID.t): unit =
  let ra = uf_find st a and rb = uf_find st b in
  if not (ID.equal ra rb) then (
    ID.Tbl.replace st.uf_parent ra rb;
    if ID.Tbl.mem st.uf_poison ra then ID.Tbl.replace st.uf_poison rb ();
    match ID.Tbl.get st.uf_ty ra with
      | Some ty -> ID.Tbl.remove st.uf_ty ra; set_type st rb ty
      | None -> ()
  )

(* the class's type; [None] for a poisoned class, which has no safe type *)
let type_of (st:parse_state) (id:ID.t): ty option =
  let r = uf_find st id in
  if ID.Tbl.mem st.uf_poison r then None else ID.Tbl.get st.uf_ty r

(* the id of the smbc unknown named [s]; repeated occurrences share one id *)
let unknown_id (st:parse_state) (s:string): ID.t =
  match StrTbl.get st.unknowns s with
    | Some id -> id
    | None -> let id = ID.make s in StrTbl.add st.unknowns s id; id

(* Two assumptions about smbc's answers, load-bearing and written nowhere else:
   - smbc problems are monomorphic, so a type recovered for an unknown never
     needs type arguments;
   - a name starting with "?" that the erase table does not know is an
     unknown of smbc's.  No problem constant reaches TIP under such a name
     ({!Lexer.mll} lexes "?" as a standalone token), and consulting the erase
     table first makes that a preference rather than a requirement.
   Unknowns get their own table, so they never enter {!erase}. *)
let id_of_tip (st:parse_state) (penv:parse_env) (s:string):
  [`Var of _ Var.t | `Const of ID.t | `Undef of ID.t | `Subst of term] =
  (* look first in the local environment for bound variables,
     then in the {!ID.Erase} table, then at the shape of the name *)
  begin match StrMap.get s penv with
    | Some (`Var v) -> `Var v
    | Some (`Subst t) -> `Subst t
    | None ->
      begin match id_of_string s with
        | Some id -> `Const id
        | None when s<>"" && s.[0] = '?' ->
          (* every occurrence must take the `Undef branch, so that it can
             become a typed hole (see {!term_of_id}) *)
          `Undef (unknown_id st s)
        | None when s<>"" && s.[0] = '$' ->
          (* domain element. They have the "distinct" property *)
          let id = ID.make_full ~needs_at:false ~distinct:true s in
          ID.Erase.add_name erase s id;
          `Const id
        | None ->
          error_parse_modelf "expected ID, got unknown `%s`" s
      end
  end

(* the smbc unknown at the head of [t], applied or not, whether or not a
   type has already been attached to it.  Constraints are about the
   unknown's identity, not about what conversion happened to learn first:
   keying on the untyped form alone silently drops every constraint on an
   unknown that has already picked up a type somewhere. *)
let unknown_head_ (t:term): (ID.t * term list) option =
  let hd u = match T.repr u with
    | TI.Builtin (`Undefined_self c) ->
      (match T.repr c with TI.Const id -> Some id | _ -> None)
    | TI.Builtin (`Undefined_atom (id,_)) -> Some id
    | _ -> None
  in
  match T.repr t with
    | TI.App (h, args) -> (match hd h with Some id -> Some (id, args) | None -> None)
    | _ -> (match hd t with Some id -> Some (id, []) | None -> None)

(* learn "the already-converted term [t] was expected to have type [ty]".
   O(α(n)) and converts nothing. *)
let push_ty ~env (st:parse_state) (ty:ty) (t:term): unit =
  match unknown_head_ t with
    | None -> ()
    | Some (id, []) -> set_type st id ty
    | Some (id, args) ->
      (match CCList.all_some (List.map (fun a -> E.to_opt (T.ty ~env a)) args) with
        | Some tys -> set_type st id (T.ty_arrow_l tys ty)
        | None -> ())

(* Every [A.term] node is converted exactly once: no call below takes an
   argument another call already took.  Type information travels two ways,
   and neither is a re-conversion: [ty] is threaded downward and gives types
   to structures (a lambda body, an [if] branch); the typed-unknown
   environment above collects constraints on unknowns by identity, and
   {!repair_holes} applies them once the whole model has been read.

   [ty], when known, is the expected type of [t]; see {!term_of_id}. *)
let rec term_of_tip st ~env ?ty (penv:parse_env) (t:A.term): term =
  match A.t_view t with
  | A.True -> T.true_
  | A.False -> T.false_
  | A.Const c -> term_of_id st ?ty penv c
  | A.App (f,l) ->
    (match id_of_tip st penv f with
     | `Undef id ->
       (* unknown in head position: synthesize its arrow type from the
          argument types and the expected result type (the same inference
          {!ElimTypes.decode_term} performs); nothing is invented.  With any
          component missing, keep the old opaque hole. *)
       let l = List.map (term_of_tip st ~env penv) l in
       let head = match ty with
         | Some ret ->
           (match CCList.all_some (List.map (fun a -> E.to_opt (T.ty ~env a)) l) with
            | Some tys ->
              let ty_h = T.ty_arrow_l tys ret in
              set_type st id ty_h;
              T.builtin (`Undefined_atom (id, ty_h))
            | None -> T.undefined_self (T.const id))
         | None -> T.undefined_self (T.const id)
       in
       T.app head l
     | _ ->
       let f = term_of_id st penv f in
       (* expected type of each argument, from the head's type when known *)
       let ty_args = match E.to_opt (T.ty ~env f) with
         | Some ty_f -> let _, args, _ = T.ty_unfold ty_f in args
         | None -> []
       in
       T.app f
         (List.mapi
            (fun i a -> term_of_tip st ~env ?ty:(List.nth_opt ty_args i) penv a)
            l))
  | A.HO_app (f,a) ->
    (* the head's identity is resolved once: two [id_of_tip] calls on the
       same name could not disagree, but nothing said so *)
    let undef_head = match A.t_view f with
      | A.Const c -> (match id_of_tip st penv c with `Undef id -> Some id | _ -> None)
      | _ -> None
    in
    (match undef_head with
     | Some id ->
       (* unknown head of a unary application: same synthesis as A.App *)
       let a = term_of_tip st ~env penv a in
       let head = match ty, E.to_opt (T.ty ~env a) with
         | Some ret, Some ty_a ->
           let ty_h = T.ty_arrow_l [ty_a] ret in
           set_type st id ty_h;
           T.builtin (`Undefined_atom (id, ty_h))
         | _ -> T.undefined_self (T.const id)
       in
       T.app head [a]
     | None ->
       (* propagate the expected type into the function: converting the
          argument first gives its type, and [ty_a -> ty] is the function's
          expected type -- this is what carries expectations through the
          [(fun x. ...) arg] redexes smbc emits *)
       let a0 = term_of_tip st ~env penv a in
       let ty_f = match E.to_opt (T.ty ~env a0), ty with
         | Some ty_a, Some ret -> Some (T.ty_arrow ty_a ret)
         | _ -> None
       in
       let f = term_of_tip st ~env ?ty:ty_f penv f in
       (* no expectation was built for [f], so the argument's expected type
          has to come back from [f]'s: register it instead of converting the
          argument a second time *)
       if CCOption.is_none ty_f then (
         match E.to_opt (T.ty ~env f) with
           | Some ty_f ->
             (match T.ty_unfold ty_f with
                | _, ty_a :: _, _ -> push_ty ~env st ty_a a0
                | _ -> ())
           | None -> ()
       );
       T.app f [a0])
  | A.Match (u,l) ->
    (* recover type info on the scrutinee; when it has none of its own
       (e.g. it is an unknown), its datatype is the result type of any
       branch constructor *)
    let ty_of_branches () =
      l |> CCList.find_map
        (function
          | A.Match_case (c_str, _, _) ->
            (match id_of_string c_str with
             | Some c_id ->
               (match Env.find_ty ~env c_id with
                | Some ty_c -> let _, _, ret = T.ty_unfold ty_c in Some ret
                | None -> None)
             | None -> None)
          | A.Match_default _ -> None)
    in
    let u = term_of_tip st ~env penv u in
    let ty_u = match E.to_opt (T.ty ~env u) with
      | Some ty_u -> ty_u
      | None ->
        (match ty_of_branches () with
         | Some ty_u -> push_ty ~env st ty_u u; ty_u
         | None ->
           (* every branch is a "default": nothing in the match names the
              scrutinee's datatype, and the scrutinee has no type of its own *)
           error_parse_modelf
             "cannot find the datatype matched on in `@[%a@]`:@ \
              the scrutinee has no type and no branch names a constructor"
             A.pp_term t)
    in
    let tydef = match T.info_of_ty_exn ~env ty_u |> Env.def with
      | Env.Data (_, _, tydef) -> tydef
      | _ ->
        error_parse_modelf
          "expected `@[%a@]`,@ of type `@[%a@]`,@ to be a datatype"
          T.pp u T.pp ty_u
    in
    (* build match tree *)
    let m, def =
      List.fold_left
        (fun (m, def) branch -> match branch, def with
           | A.Match_case (c_str, vars, rhs), _ ->
             let c_id = match id_of_string c_str with
               | Some i -> i
               | None ->
                 error_parse_modelf
                   "cannot find a constructor corresponding to `%s`" c_str
             in
             let c_ty_args = match ID.Map.get c_id (Stmt.data_cstors tydef) with
               | None ->
                 error_parse_modelf "id `%a` should be a constructor of `@[%a@]`"
                   ID.pp c_id T.pp ty_u
               | Some cstor -> cstor.Stmt.cstor_args
             in
             if List.length c_ty_args <> List.length vars then (
               error_parse_modelf
                 "constructor `%a` takes %d argument(s),@ but the branch binds %d"
                 ID.pp c_id (List.length c_ty_args) (List.length vars)
             );
             let penv, vars =
               CCList.fold_map add_typed_var penv (List.combine vars c_ty_args)
             in
             let rhs = term_of_tip st ~env ?ty penv rhs in
             ID.Map.add c_id ([],vars,rhs) m, def
           | A.Match_default _, Some _ ->
             error_parse_modelf
               "two distinct \"default\" clauses in `@[%a@]`"
               A.pp_term t
           | A.Match_default rhs, None ->
             m, Some (term_of_tip st ~env ?ty penv rhs))
        (ID.Map.empty, None)
        l
    in
    let def = match def with
      | None -> None
      | Some rhs ->
        let missing =
          Stmt.data_cstors tydef
          |> ID.Map.filter (fun id _ -> not (ID.Map.mem id m))
          |> ID.Map.map (fun cstor -> List.length cstor.Stmt.cstor_args)
        in
        Some (rhs, missing)
    in
    T.match_with u m ~def
  | A.If (a,b,c) ->
    T.No_simp.ite (term_of_tip st ~env ~ty:T.ty_prop penv a)
      (term_of_tip st ~env ?ty penv b) (term_of_tip st ~env ?ty penv c)
  | A.Let (l,u) ->
    let penv = List.fold_left
        (fun penv (s,t) ->
           let t = term_of_tip st ~env penv t in
           StrMap.add s (`Subst t) penv)
        penv l
    in
    term_of_tip st ~env ?ty penv u
  | A.Fun (v,body) ->
    let penv, v = typed_var_of_tip st penv v in
    (* the expectation must agree with the domain smbc declared for the
       lambda.  Disagreement means the expectation is wrong, so drop it: an
       assertion here would turn a bad expectation into a lost verdict *)
    let ty_body = match ty with
      | Some ty_f ->
        (match T.repr ty_f with
         | TI.TyArrow (dom, r) when T.equal dom (Var.ty v) -> Some r
         | TI.TyArrow (dom, _) ->
           Utils.warningf Utils.Warn_model_parsing_error
             "expected a function on `@[%a@]`,@ but the model binds `@[%a@]`"
             T.pp dom Var.pp_full v;
           None
         | _ -> None)
      | None -> None
    in
    let body = term_of_tip st ~env ?ty:ty_body penv body in
    T.fun_ v body
  | A.Eq (a,b) ->
    (* both sides share a type: register that, then give the class whatever
       type either side turns out to carry *)
    let a0 = term_of_tip st ~env penv a in
    let b0 = term_of_tip st ~env penv b in
    (* only bare heads: for [(?f x) = (?g y)] it is the *results* that share
       a type, not the heads *)
    (match unknown_head_ a0, unknown_head_ b0 with
     | Some (ia, []), Some (ib, []) -> same_type st ia ib
     | _ -> ());
    (match E.to_opt (T.ty ~env a0), E.to_opt (T.ty ~env b0) with
     | Some ty_a, _ -> push_ty ~env st ty_a b0
     | _, Some ty_b -> push_ty ~env st ty_b a0
     | None, None -> ());
    T.No_simp.eq a0 b0
  | A.Imply (a,b) ->
    T.No_simp.imply (term_of_tip st ~env ~ty:T.ty_prop penv a)
      (term_of_tip st ~env ~ty:T.ty_prop penv b)
  | A.And l ->
    let l = List.map (term_of_tip st ~env ~ty:T.ty_prop penv) l in
    T.No_simp.and_ l
  | A.Distinct l ->
    (* all elements share one type: any typed element determines it.
       Registration runs over the element list, not over the O(n²)
       expansion below. *)
    let l = List.map (term_of_tip st ~env penv) l in
    (match
       CCList.filter_map
         (fun t -> match unknown_head_ t with Some (i, []) -> Some i | _ -> None) l
     with
      | i0 :: rest -> List.iter (same_type st i0) rest
      | [] -> ());
    (match CCList.find_map (fun t -> E.to_opt (T.ty ~env t)) l with
      | Some ty_elt -> List.iter (push_ty ~env st ty_elt) l
      | None -> ());
    CCList.diagonal l
    |> List.map (fun (a,b) -> T.No_simp.neq a b)
    |> T.No_simp.and_
  | A.Or l ->
    let l = List.map (term_of_tip st ~env ~ty:T.ty_prop penv) l in
    T.No_simp.or_ l
  | A.Not a -> T.No_simp.not_ (term_of_tip st ~env ~ty:T.ty_prop penv a)
  | A.Forall (v,body) ->
    let penv, v = CCList.fold_map (typed_var_of_tip st) penv v in
    let body = term_of_tip st ~env ~ty:T.ty_prop penv body in
    T.forall_l v body
  | A.Exists (v,body) ->
    let penv, v = CCList.fold_map (typed_var_of_tip st) penv v in
    let body = term_of_tip st ~env ~ty:T.ty_prop penv body in
    T.exists_l v body
  | A.Cast (_,_) -> assert false

and term_of_id (st:parse_state) ?ty (env:parse_env) (s:string): term = match id_of_tip st env s with
  | `Const id -> T.const id
  | `Undef id ->
    (* an unknown constant of smbc's, e.g. "?a__2". When the expected type
       is known, make it an [`Undefined_atom], which prints as "?__<n>" --
       a form model consumers can parse back. [id] was freshly allocated by
       [id_of_tip], so it cannot clash with any other id. With no type at
       hand, ask the typed-unknown environment -- {!A.Match} needs the
       scrutinee's datatype *during* conversion, so a type the repair pass
       would supply arrives too late. Failing both, the old opaque hole. *)
    (match ty with
     | Some ty -> set_type st id ty; T.builtin (`Undefined_atom (id, ty))
     | None ->
       (match type_of st id with
        | Some ty -> T.builtin (`Undefined_atom (id, ty))
        | None -> T.undefined_self (T.const id)))
  | `Subst t -> t
  | `Var v -> T.var v

and ty_of_tip (st:parse_state) (ty:A.ty): ty = match A.ty_view ty with
  | A.Ty_bool -> T.ty_prop
  | A.Ty_arrow (l, ret) ->
    T.ty_arrow_l (List.map (ty_of_tip st) l) (ty_of_tip st ret)
  | A.Ty_app (f, l) ->
    T.ty_app (term_of_id st empty_penv f) (List.map (ty_of_tip st) l)

and typed_var_of_tip (st:parse_state) (env:parse_env) (s,ty) =
  let ty = ty_of_tip st ty in
  add_typed_var env (s,ty)

and add_typed_var env (s,ty) =
  let id = ID.make s in
  let v = Var.of_id id ~ty in
  StrMap.add s (`Var v) env, v

(* convert a term with functions inside tests into one single function
   with tests in the body.
   Example:
   [if a then (fun x. if x then (fun y.true) else (fun y.false)) else (fun x' y'. x and y)]
   should become
   [fun x y.
    if a then
      if x then true else false
    else x and y]
*)
let extract_to_outer_function (t:term): term =
  let rec merge_ty_lists l1 l2 = match l1, l2 with
    | [], _ | _, [] -> []
    | ty1 :: tail1, ty2 :: tail2 ->
      assert (T.equal ty1 ty2); (* by well-typedness *)
      ty1 :: merge_ty_lists tail1 tail2
  in
  (* first, find the list of variables' types that
     are available in *all* branches in the same order.
     Above it would return [typeof x, typeof y] *)
  let rec extract_ty_args t : ty list = match T.repr t with
    | TI.Bind (Binder.Fun, v, u) -> Var.ty v :: extract_ty_args u
    | TI.Builtin (`Ite (_, a, b)) -> merge_ty_lists (extract_ty_args a) (extract_ty_args b)
    | TI.Match (_, m, def) ->
      assert (not (ID.Map.is_empty m));
      let id, (_, _, rhs) = ID.Map.min_binding m in
      let args0 = extract_ty_args rhs in
      let m = ID.Map.remove id m in
      let args =
        ID.Map.fold
          (fun _ (_, _, rhs) m -> merge_ty_lists m (extract_ty_args rhs))
          m args0
      in
      begin match def with
        | None -> args
        | Some (rhs,_) ->
          merge_ty_lists args (extract_ty_args rhs)
      end
    | _ -> []
  in
  (* transform [t] to extract its function part outside
     @param vars the list of variables still available to rename
      function parameters in [t]
     @param subst variables already substituted *)
  let rec transform fun_vars subst t = match T.repr t, fun_vars with
    | _, [] ->
      (* no more variables, must be a leaf, just rename variables *)
      T.eval_renaming ~subst t
    | TI.Bind (Binder.Fun, v, body), new_v :: vars_tail ->
      assert (not (Var.Subst.mem ~subst v));
      let subst = Var.Subst.add ~subst v new_v in
      transform vars_tail subst body
    | TI.Builtin (`Ite (a,b,c)), _ ->
      T.ite
        (T.eval_renaming ~subst a)
        (transform fun_vars subst b)
        (transform fun_vars subst c)
    | TI.Match (u, m, def), _ ->
      T.match_with
        (T.eval_renaming ~subst u)
        (ID.Map.map
           (fun (tys, vars, rhs) ->
              let subst, vars =
                CCList.fold_map Var.Subst.rename_var subst vars
              in
              tys, vars, transform fun_vars subst rhs)
           m)
        ~def:(TI.map_default_case (transform fun_vars subst) def)
    | _ ->
      assert false (* [fun_vars=[]] should hold *)
  in
  let ty_args = extract_ty_args t in
  let module TyMo = TypeMono.Make(T) in
  let vars =
    List.mapi
      (fun i ty -> Var.makef ~ty "%s_%d" (TyMo.mangle ~sep:"_" ty) i)
      ty_args
  in
  T.fun_l vars (transform vars Var.Subst.empty t)

(* convert a term into a decision tree *)
let dt_of_term (t:term): (term,ty) Model.DT.t =
  let fail_ ~vars t =
    error_parse_modelf
      "expected leaf or test against a variable in [@[%a@]],@ got: `@[%a@]`"
      (CCFormat.list Var.pp_full) vars T.pp t
  in
  (* check that [t] is an equation [v = t'], return [t'].
     otherwise returns [None] *)
  let get_eqn_exn v vars_tail t: term option =
    let fail() =
      error_parse_modelf
        "expected a test <%a = term>,@ but got `@[%a@]`@]"
        Var.pp_full v T.pp t
    in
    Utils.debugf 5 "get_eqn var=`%a` on: `@[%a@]`"
      (fun k->k Var.pp_full v T.pp t);
    match T.repr t with
      | TI.Builtin (`Eq (t1, t2)) ->
        begin match T.repr t1, T.repr t2 with
          | TI.Var v', _ when Var.equal v v' -> Some t2
          | _, TI.Var v' when Var.equal v v' -> Some t1
          | TI.Var v', _ when List.exists (Var.equal v') vars_tail -> None
          | _, TI.Var v' when List.exists (Var.equal v') vars_tail -> None
          | _ -> fail()
        end
      | TI.Var v' when Var.equal v v' ->
        assert (T.ty_is_Prop (Var.ty v'));
        Some T.true_
      | TI.Var v' when List.exists (Var.equal v') vars_tail -> None
      | TI.Var _ ->
        error_parse_modelf
          "expected a boolean variable among @[%a@],@ but got @[%a@]@]"
          Var.pp_full v T.pp t
      | _ -> fail()
  in
  (* recursive conversion *)
  let rec conv_body ~vars t : (_,_) Model.DT.t =
    match T.repr t, vars with
      | _, [] -> Model.DT.yield t
      | TI.Builtin (`Ite (_,_,_)), v :: vars_tail ->
        let tests, else_ = T.ite_unfold t in
        let tests_v, other_tests =
          CCList.partition_filter_map
            (fun (a, b) ->
               match get_eqn_exn v vars_tail a with
                 | Some t ->
                   let b = conv_body ~vars:vars_tail b in
                   `Left (t, b)
                 | None -> `Right (a, b))
            tests
        in
        (* default contains both tests on [vars_tail] and the [else_] branch *)
        let default =
          let t' =
            List.fold_right (fun (a,b) c -> T.ite a b c) other_tests else_
          in
          Some (conv_body ~vars:vars_tail t')
        in
        Model.DT.mk_tests v ~tests:tests_v ~default
      | (TI.Const _ | TI.App _ | TI.Var _ | TI.Bind _ | TI.Builtin _), _::_ ->
        (* yield early, as a constant branch *)
        Model.DT.const vars (Model.DT.yield t)
      | TI.Match (u, m, def), v :: vars_tail ->
        begin match T.repr u with
          | TI.Var v' when Var.equal v v' ->
            let m =
              ID.Map.map
                (fun (tys, local_vars, rhs) ->
                   assert (tys = []);
                   tys, local_vars, conv_body ~vars:(local_vars @ vars_tail) rhs)
                m
            and def, missing = match def with
              | None -> None, ID.Map.empty
              | Some (d,missing) ->
                Some (conv_body ~vars:vars_tail d), missing
            in
            Model.DT.mk_match v ~by_cstor:m ~default:def ~missing
          | TI.Var v' when List.exists (Var.equal v') vars_tail ->
            (* test on a variable that comes later. *)
            Model.DT.const [v] (conv_body ~vars:vars_tail t)
          | _ ->
            fail_ ~vars t
        end
      | (TI.Let _ | TI.TyMeta _ | TI.TyArrow _ | TI.TyBuiltin _), _::_ ->
        fail_ ~vars t
  in
  let vars, body = T.fun_unfold t in
  (* change the shape of [body] so it looks more like a decision tree *)
  let dt = conv_body ~vars body in
  Utils.debugf ~section 5
    "@[<2>turn term `@[%a@]`@ into DT `@[%a@]`@]"
    (fun k->k T.pp body (Model.DT.pp T.pp' T.pp) dt);
  dt

module A_res = A.Smbc_res

(* One linear pass over a finished value term, applying what the
   typed-unknown environment learned anywhere in the model.  It runs after
   every entry has been converted, which is what makes recovery independent
   of the order in which smbc emitted its entries.  No fixpoint: the
   union-find is already confluent. *)
let repair_holes (st:parse_state) (t:term): term =
  let bind () v = (), v in
  let rec aux () t =
    match T.repr t with
      | TI.Builtin (`Undefined_atom (id, ty)) when is_poisoned st id ->
        (* the class carries two types; never let one identity stand for
           both.  [`Unparsable] is what model consumers already understand *)
        T.builtin (`Unparsable ty)
      | _ ->
        match unknown_head_ t with
          | Some (id, args) ->
            (match type_of st id with
               (* the arity guard: a base-typed entry spliced into head
                  position would yield an ill-typed application *)
               | Some ty when
                   (let _, ty_args, _ = T.ty_unfold ty in
                    List.length ty_args >= List.length args) ->
                 T.app (T.builtin (`Undefined_atom (id, ty))) (List.map (aux ()) args)
               | _ -> T.map ~f:aux ~bind () t)
          | None -> T.map ~f:aux ~bind () t
  in
  aux () t

let convert_model ~env (m:A_res.model): (_,_) Model.t =
  let st = mk_parse_state () in
  (* Pre-scan: declare every domain element ("$a__0") with its type.
     Domain elements are minted by {!id_of_tip} and appear in no problem
     statement, so without this the expected-type recovery in
     {!term_of_tip} cannot see through them.  A pre-scan (rather than
     relying on Ty entries preceding Val entries in smbc's output) makes
     the invariant independent of emission order. *)
  let env =
    List.fold_left
      (fun env e -> match e with
         | A_res.Ty (ty, dom) ->
           let ty = ty_of_tip st ty in
           List.fold_left
             (fun env s -> match id_of_tip st empty_penv s with
                | `Const id | `Undef id ->
                  if CCOption.is_none (Env.find_ty ~env id)
                  then Env.declare ~attrs:[] ~env id ty
                  else env
                | `Subst _ | `Var _ -> env)
             env dom
         | A_res.Val _ -> env)
      env m
  in
  let find_kind (t:term): Model.symbol_kind =
    let fail() =
      Utils.warningf Utils.Warn_model_parsing_error
        "cannot find symbol_kind for `@[%a@]`" T.pp t;
      Model.Symbol_fun
    in
    match T.repr t with
      | TI.Const id ->
        begin match Env.find_ty ~env id with
          | Some ty ->
            if T.ty_returns_Prop ty then Model.Symbol_prop else Model.Symbol_fun
          | None -> fail()
        end
      | _ -> fail()
  in
  (* Two phases.  Converting every entry first fills the typed-unknown
     environment; only then can the repair pass apply a type that a *later*
     entry determined. *)
  let entries =
    List.map
      (function
        | A_res.Ty (ty, dom) ->
          let ty = ty_of_tip st ty in
          let dom =
            List.map
              (fun s -> match id_of_tip st empty_penv s with
                 | `Subst _
                 | `Var _ -> error_parse_modelf "invalid domain element %s" s
                 | `Const id
                 | `Undef id -> id)
              dom
          in
          `Ty (ty, dom)
        | A_res.Val (a,b) ->
          let a = term_of_tip st ~env empty_penv a in
          let ty_a = E.to_opt (T.ty ~env a) in
          (* a value we cannot read costs that value -- not the verdict, not
             the sibling backends, and not the rest of the model *)
          let b =
            try term_of_tip st ~env ?ty:ty_a empty_penv b
            with e when is_model_conversion_error e ->
              (match ty_a with
                 | Some ty ->
                   Utils.warningf Utils.Warn_model_parsing_error
                     "cannot read the value of `@[%a@]`: %s"
                     T.pp a (Printexc.to_string e);
                   T.builtin (`Unparsable ty)
                 | None -> raise e)
          in
          `Val (a, b))
      m
  in
  List.fold_left
    (fun m e -> match e with
       | `Ty (ty, dom) -> Model.add_finite_type m ty dom
       | `Val (a,b) ->
         (* conversion of [b] into a proper decision tree *)
         let b = b |> repair_holes st |> extract_to_outer_function |> dt_of_term in
         let k = find_kind a in
         Model.add_value m (a,b,k))
    Model.empty entries

(* the problem metadata is merged into the answer by [Mark_spurious], the
   stage [close_task] composes for every backend; do not do it here *)
let convert_res ~env ~info (res:A_res.t): (_,_) Res.t * S.shortcut = match res with
  | A_res.Timeout -> Res.Unknown [Res.U_timeout info], S.No_shortcut
  | A_res.Unknown s -> Res.Unknown [Res.U_other (info,s)], S.No_shortcut
  | A_res.Unsat -> Res.Unsat info, S.Shortcut
  | A_res.Sat m -> Res.Sat (convert_model ~env m, info), S.Shortcut

(* parse [stdout, errcode] into a proper result *)
let parse_res ~env ~info (out:string) (errcode:int): (term,ty) Res.t * S.shortcut =
  if errcode<>0
  then
    let msg = Printf.sprintf "smbc failed with errcode %d, output:\n`%s`" errcode out in
    Res.Unknown [Res.U_backend_error (info, msg)], S.No_shortcut
  else (
    try
      let lexbuf = Lexing.from_string out in
      Location.set_file lexbuf "<output of smbc>";
      let res = Tip_parser.parse_smbc_res Tip_lexer.token lexbuf in
      convert_res ~env ~info res
    with e ->
      (* Being unable to read smbc's output is a backend error, exactly like
         the non-zero exit code above.  Reporting it as [Res.Error] with a
         shortcut is worse than a crash of smbc itself: it stops the sibling
         backends, so a cvc5 answer to the same problem is lost to a defect
         in smbc's output. *)
      let msg =
        Printf.sprintf "could not read smbc's output: %s" (Printexc.to_string e)
      in
      Res.Unknown [Res.U_backend_error (info, msg)], S.No_shortcut
  )

(** {2 Main Solving} *)

(* step between successive depths in iterative deepening *)
let depth_step_ = 1 (* FUDGE *)

let solve ~deadline pb =
  Utils.debug ~section 1 "calling smbc";
  let now = Unix.gettimeofday() in
  if now +. 0.5 > deadline
  then
    let i = Res.mk_info ~backend:"smbc" ~time:0. () in
    Res.Unknown [Res.U_timeout i], S.No_shortcut
  else (
    let timer = Utils.Time.start_timer () in
    let mk_info ?msg () =
      Res.mk_info ?message:msg
        ~backend:"smbc" ~time:(Utils.Time.get_timer timer) ()
    in
    let timeout = (int_of_float (deadline -. now +. 1.5)) in
    (* call solver and communicate over stdin *)
    let cmd =
      Printf.sprintf "%s -t %d -nc --depth-step %d --check --stdin 2>&1"
        (Filename.quote (smbc_program_ ())) timeout depth_step_
    in
    Utils.debugf ~section 5 "smbc call: `%s`" (fun k->k cmd);
    (* print problem into a TIP string;
       also serves to check Out_of_scope *)
    try
      let pb_string = CCFormat.sprintf "@[<v>%a@]@." pp_pb pb in
      let fut =
        S.popen cmd
          ~f:(fun (stdin,stdout) ->
            Utils.debugf ~lock:true ~section 5 "smbc input:@ %s" (fun k->k pb_string);
            (* send problem *)
            output_string stdin pb_string;
            flush stdin;
            close_out stdin;
            CCIO.read_all stdout)
      in
      begin match S.Fut.get fut with
        | S.Fut.Done (E.Ok (stdout, errcode)) ->
          Utils.debugf ~lock:true ~section 2
            "@[<2>smbc exited with %d, stdout:@ `%s`@]"
            (fun k->k errcode stdout);
          let info = mk_info() in
          (* need environment to re-infer some types *)
          let env = Problem.env pb in
          parse_res ~env ~info stdout errcode
        | S.Fut.Done (E.Error e) ->
          let info = mk_info() in
          Res.Error (e,info), S.Shortcut
        | S.Fut.Stopped ->
          let info = mk_info() in
          Res.Unknown [Res.U_timeout info], S.No_shortcut
        | S.Fut.Fail e ->
          (* return error *)
          Utils.debugf ~lock:true ~section 1 "@[<2>smbc failed with@ `%s`@]"
            (fun k->k (Printexc.to_string e));
          let info = mk_info() in
          Res.Error (e,info), S.Shortcut
      end
    with Out_of_scope msg ->
      Utils.debugf ~section 3 "@[out of scope because:@ %s@]"
        (fun k->k msg);
      let info = mk_info ~msg () in
      Res.Unknown [Res.U_out_of_scope info], S.No_shortcut (* out of scope *)
  )

let call_real ~print_model ~prio problem =
  S.Task.make ?prio
    (fun ~deadline () ->
       let res, short = solve ~deadline problem in
       Utils.debugf ~section 2 "@[<2>smbc result:@ %a@]"
         (fun k->k Res.pp_head res);
       begin match res with
         | Res.Sat (m,_) when print_model ->
           let pp_ty oc _ = CCFormat.string oc "$i" in
           Format.printf "@[<2>raw smbc model:@ @[%a@]@]@."
             (Model.pp T.pp' pp_ty) m
         | _ -> ()
       end;
       res, short)

(* solve problem before [deadline] *)
let call ?(print_model=false) ?prio ~print ~dump problem =
  if print then (
    let module P_pb = Problem.P in
    Format.printf "@[<v2>SMBC problem:@ %a@]@." P_pb.pp problem;
  );
  begin match dump with
    | None -> call_real ~print_model ~prio problem
    | Some file ->
      let file = file ^ ".smbc.smt2" in
      Utils.debugf ~section 1 "output smbc problem into `%s`" (fun k->k file);
      CCIO.with_out file
        (fun oc ->
           let out = Format.formatter_of_out_channel oc in
           Format.fprintf out "@[<v>; generated by nunchaku@ %a@]@." pp_pb problem);
      let i = Res.mk_info ~backend:"smbc" ~time:0. () in
      S.Task.return (Res.Unknown [Res.U_other (i, "--dump")]) S.No_shortcut
  end

let pipe ?(print_model=false) ?(prio=20) ~print ~dump () =
  let input_spec =
    Transform.Features.(of_list [
        Ty, Mono; If_then_else, Present;
        Eqn, Eqn_single; Codata, Absent;
        Copy, Absent; Ind_preds, Absent; Prop_args, Present;
      ])
  in
  let encode pb = call ~print_model ~prio ~print ~dump pb, () in
  Transform.make
    ~input_spec
    ~name ~encode ~decode:(fun _ x -> x) ()
