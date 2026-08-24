(* Nitpick vs Nunchaku countermodel benchmark.
   Env: BENCH_ENGINE = nitpick | nunchaku | nunchaku_smbc | nunchaku_ship
        BENCH_TIER   = seconds (e.g. "1" or "5")
   Emits lines: RESULT\tclass\tid\ttruth\tengine\ttier\tverdict\tms\tmodel *)

val engine = getenv "BENCH_ENGINE";
val tier = getenv "BENCH_TIER";
val tier_s = (case Int.fromString tier of SOME n => n | NONE => error "bad BENCH_TIER");

val thy0 = Thy_Info.get_theory "Main";
val ctxt0 = Proof_Context.init_global thy0;
val state0 = Proof.init ctxt0;

(* (class, id, truth, prop)  truth: "F" = false (countermodel expected), "T" = true *)
val goals : (string * string * string * string) list = [
  (* 1: linear arithmetic *)
  ("arith_lin", "l1", "F", "(n::nat) + m = n * m"),                    (* n=1,m=2 *)
  ("arith_lin", "l2", "F", "(n::nat) - m + m = n"),                    (* n=0,m=1 *)
  ("arith_lin", "l3", "F", "(a::int) mod b < b"),                      (* a=0,b=0 *)
  ("arith_lin", "l4", "F", "(n::nat) < n + m"),                        (* m=0 *)
  ("arith_lin", "l5", "T", "(n::nat) <= n + m"),
  ("arith_lin", "l6", "T", "(a::int) + b = b + a"),
  ("arith_lin", "l7", "T", "(n::nat) - n = 0"),
  (* 2: nonlinear arithmetic *)
  ("arith_nl", "n1", "T", "(a::int) * a >= a"),
  ("arith_nl", "n2", "F", "(a::int) * b = b"),                         (* a=2,b=1 *)
  ("arith_nl", "n3", "F", "(n::nat) * n = n"),                         (* n=2 *)
  ("arith_nl", "n4", "F", "(a::int) * a > 0"),                         (* a=0 *)
  ("arith_nl", "n5", "T", "(n::nat) * m = m * n"),
  ("arith_nl", "n6", "T", "(a::int) * a >= 0"),
  ("arith_nl", "n7", "F", "(n::nat) ^ 2 > n"),                         (* n=0 or 1 *)
  ("arith_nl", "n8", "T", "(n::nat) <= n * n + 1"),
  (* 3: lists *)
  ("list", "ls1", "F", "hd (xs @ ys) = hd xs"),                        (* xs=[], ys=[a], a ~= hd [] *)
  ("list", "ls2", "F", "rev (xs @ ys) = rev xs @ rev ys"),             (* xs=[a],ys=[b] *)
  ("list", "ls3", "F", "length (removeAll x xs) = length xs - 1"),     (* xs=[y], y~=x *)
  ("list", "ls4", "F", "distinct (xs @ xs)"),                          (* xs=[a] *)
  ("list", "ls5", "T", "rev (rev xs) = xs"),
  ("list", "ls6", "T", "length (xs @ ys) = length xs + length ys"),
  ("list", "ls7", "T", "set (rev xs) = set xs"),
  ("list", "ls8", "F", "map f (xs::'a list) = xs"),                    (* f x ~= x *)
  (* 4: option / pair / sum *)
  ("opt", "o1", "F", "the (map_option f (x::'a option)) = f (the x)"), (* x=None *)
  ("opt", "o2", "F", "fst (p::'a * 'a) = snd p"),
  ("opt", "o3", "F", "map_option f (x::'a option) ~= None"),           (* x=None *)
  ("opt", "o4", "T", "map_option f (Some a) = Some (f a)"),
  ("opt", "o5", "T", "fst (a, b) = a"),
  ("opt", "o6", "F", "isl (s::'a + 'b)"),                              (* s=Inr b *)
  ("opt", "o7", "T", "Inl a ~= Inr b"),
  (* 5: sets *)
  ("set", "s1", "F", "A - (B - C) = (A - B) - (C::'a set)"),           (* A=C={a},B={} *)
  ("set", "s2", "F", "card (A \<union> B) = card A + card (B::'a set)"), (* A=B={a} *)
  ("set", "s3", "T", "A \<inter> B \<subseteq> (A::'a set)"),
  ("set", "s4", "T", "A \<union> B = B \<union> (A::'a set)"),
  ("set", "s5", "F", "insert x A = (A::'a set)"),                      (* x notin A *)
  ("set", "s6", "T", "x \<in> insert x (A::'a set)"),
  (* 6: quantifiers inside the goal *)
  ("quant", "q1", "F", "\<forall>n::nat. \<exists>m. m < n"),        (* n=0 *)
  ("quant", "q2", "T", "\<forall>n::nat. \<exists>m. n < m"),
  ("quant", "q3", "F", "\<forall>xs::nat list. \<exists>x. x \<in> set xs"), (* xs=[] *)
  ("quant", "q4", "T", "\<forall>n::nat. n = 0 | (\<exists>m. n = Suc m)"),
  ("quant", "q5", "F", "\<forall>a b::nat. a <= b --> b <= a"),       (* a=0,b=1 *)
  ("quant", "q6", "T", "\<forall>xs::nat list. sorted (sort xs)"),
  (* 7: exists-wrapped over infinite type *)
  ("exwrap", "e1", "F", "\<exists>n::nat. \<forall>m::nat. m <= n"),
  ("exwrap", "e2", "T", "\<exists>xs::nat list. \<forall>a. a \<in> set xs --> a = 0"), (* witness [] *)
  ("exwrap", "e3", "F", "\<exists>f::nat=>nat. \<forall>n. f n < n"), (* f 0 < 0 impossible *)
  ("exwrap", "e4", "T", "\<exists>n::nat. \<forall>m::nat. n <= m"),  (* witness 0 *)
  ("exwrap", "e5", "F", "\<exists>xs::nat list. \<forall>n::nat. n \<in> set xs"),
  ("exwrap", "e6", "T", "\<exists>f::nat=>nat. \<forall>n. f n <= n"), (* witness id *)
  ("exwrap", "e7", "F", "\<exists>a::int. \<forall>b::int. a <= b"),
  (* 8: higher-order *)
  ("ho", "h1", "F", "\<forall>f::nat=>nat. inj f"),                   (* const fn *)
  ("ho", "h2", "F", "map f (map g (xs::'a list)) = map g (map f xs)"), (* noncommuting f,g *)
  ("ho", "h3", "T", "map f (map g (xs::'a list)) = map (f o g) xs"),
  ("ho", "h4", "T", "(%x::'a. f x) = f"),
  ("ho", "h5", "F", "inj (%n::nat. n mod 2)"),                         (* 0,2 collide *)
  ("ho", "h6", "T", "inj (%n::nat. Suc n)"),
  ("ho", "h7", "F", "surj (%n::nat. Suc n)"),                          (* 0 unreached *)
  ("ho", "h8", "T", "surj (%n::nat. n)")
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
                else ("error(" ^ String.translate (fn #"	" => " " | #"
" => " " | c => str c) (General.exnMessage exn) ^ ")", "na"))) ()));
    val (verdict, model, ms) =
      (case verdict_timed of
        NONE => ("parse_error", "na", 0)
      | SOME ({elapsed, ...}, (v, m)) => (v, m, Time.toMilliseconds elapsed));
  in
    writeln (cat_lines []) ;
    writeln ("RESULT	" ^ cls ^ "	" ^ id ^ "	" ^ truth ^ "	" ^ engine ^ "	" ^ tier ^
             "	" ^ verdict ^ "	" ^ string_of_int ms ^ "	" ^ model)
  end;

val _ = List.app one goals;
val _ = writeln "BENCH_DONE";
