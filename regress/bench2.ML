(* Extension: custom-datatype and large-witness classes.
   Requires cwd = scratchpad (-C) so DTBench.thy is found.
   Env: BENCH_ENGINE = nitpick | nunchaku | nunchaku_smbc | nunchaku_ship ; BENCH_TIER = seconds.
   Emits: RESULT\tclass\tid\ttruth\tengine\ttier\tverdict\tms\tmodel *)

val engine = getenv "BENCH_ENGINE";
val tier = getenv "BENCH_TIER";
val tier_s = (case Int.fromString tier of SOME n => n | NONE => error "bad BENCH_TIER");

val _ = Thy_Info.use_thy_legacy "DTBench";
val thy0 = Thy_Info.get_theory "Draft.DTBench";
val ctxt0 = Proof_Context.init_global thy0;
val state0 = Proof.init ctxt0;

(* (class, id, truth, prop) *)
val goals : (string * string * string * string) list = [
  ("datatype", "d1", "F", "mirror t = t"),                                (* MNode (MNode MLeaf a MLeaf) a MLeaf *)
  ("datatype", "d2", "F", "mflatten (mirror t) = mflatten t"),           (* MNode MLeaf a (MNode MLeaf b MLeaf), a ~= b *)
  ("datatype", "d3", "F", "mmap f (mmap g t) = mmap g (mmap f t)"),      (* noncommuting f g *)
  ("datatype", "d4", "F", "mheight t = msize t"),                        (* balanced 3-node tree: 2 vs 3 *)
  ("datatype", "d5", "F", "msize (mmap f t) = msize t + 1"),             (* t = MLeaf *)
  ("datatype", "d6", "F", "next_suit s = Hearts"),                       (* s = Hearts *)
  ("datatype", "d7", "F", "swap_pt p = p"),                              (* Pt 0 1 *)
  ("datatype", "d8", "F", "px p <= py p"),                               (* Pt 1 0 *)
  ("datatype", "d9",  "T", "mirror (mirror t) = t"),
  ("datatype", "d10", "T", "msize (mirror t) = msize t"),
  ("datatype", "d11", "T", "mheight (mirror t) = mheight t"),
  ("datatype", "d12", "T", "mflatten (mmap f t) = map f (mflatten t)"),
  ("datatype", "d13", "T", "next_suit s ~= s"),
  ("datatype", "d14", "T", "swap_pt (swap_pt p) = p"),
  ("datatype", "d15", "T", "manh (swap_pt p) = manh p"),
  ("datatype", "d16", "T", "msize (mmap f t) = msize t"),
  ("arith_bigwit", "b1", "F", "(n::nat) <= 100000"),                     (* witness 100001 *)
  ("arith_bigwit", "b2", "F", "(n::nat) > 1000000 --> n mod 2 = 0"),     (* witness 1000001 *)
  ("arith_bigwit", "b3", "F", "(a::int) < 500000"),                      (* witness 500000 *)
  ("arith_bigwit", "b4", "F", "(n::nat) ~= 123456"),                     (* witness 123456 *)
  ("arith_bigwit", "b5", "T", "(n::nat) < n + 100001")
];

fun run_nitpick t =
  let
    val params = Nitpick_Commands.default_params thy0
      [("timeout", tier), ("verbose", "false"), ("max_potential", "1"),
       ("max_threads", "1"), ("falsify", "true")];
  in (fst (Nitpick.pick_nits_in_term state0 params Nitpick.Normal 1 1 0 [] [] [] t), "na") end;

(* model column: for the nunchaku engines, whether a refuting verdict came
   with a displayable model ("yes"/"no"); "na" otherwise.  The smbc
   model-hole class of defects preserves the verdict and loses only the
   model, so the gate needs this column to see them at all. *)
fun run_nunchaku solvers t =
  let
    val params = Nunchaku_Commands.default_params thy0
      [("timeout", tier), ("solvers", solvers)];
    val (verdict, model_opt) = Nunchaku.run_chaku_on_prop state0 params Nunchaku.Normal 1 [] t;
    val model =
      if verdict = Nunchaku.genuineN orelse verdict = Nunchaku.quasi_genuineN
      then (if is_some model_opt then "yes" else "no") else "na";
  in (verdict, model) end;

val run_engine =
  (case engine of
    "nitpick" => run_nitpick
  | "nunchaku" => run_nunchaku "cvc5 kodkod"
  | "nunchaku_smbc" => run_nunchaku "cvc5 kodkod smbc"
  | "nunchaku_ship" => run_nunchaku "cvc5 smbc"
  | _ => error ("bad BENCH_ENGINE: " ^ engine));

val guard = Time.fromReal (Real.fromInt tier_s + 3.0);

fun one (cls, id, truth, prop_str) =
  let
    val verdict_timed =
      (case try (Syntax.read_prop ctxt0) prop_str of
        NONE => NONE
      | SOME t =>
          SOME (Timing.timing (fn () =>
            (case Exn.capture (fn () => Timeout.apply guard run_engine t) () of
              Exn.Res v => v
            | Exn.Exn (Timeout.TIMEOUT _) => ("guard_timeout", "na")
            | Exn.Exn exn =>
                if Exn.is_interrupt exn then Exn.reraise exn
                else ("error(" ^ String.translate (fn #"\t" => " " | #"\n" => " " | c => str c) (General.exnMessage exn) ^ ")", "na"))) ()));
    val (verdict, model, ms) =
      (case verdict_timed of
        NONE => ("parse_error", "na", 0)
      | SOME ({elapsed, ...}, (v, m)) => (v, m, Time.toMilliseconds elapsed));
  in
    writeln (cat_lines []) ;
    writeln ("RESULT\t" ^ cls ^ "\t" ^ id ^ "\t" ^ truth ^ "\t" ^ engine ^ "\t" ^ tier ^
             "\t" ^ verdict ^ "\t" ^ string_of_int ms ^ "\t" ^ model)
  end;

val _ = List.app one goals;
val _ = writeln "BENCH_DONE";
