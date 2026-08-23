(* Side-check: try to PROVE each TRUE goal quickly (auto / fastforce / arith / blast).
   Emits: TRUTH\tid\tproved_by  or  TRUTH\tid\tUNPROVED *)

val thy0 = Thy_Info.get_theory "Main";
val ctxt0 = Proof_Context.init_global thy0;

val true_goals : (string * string) list = [
  ("l5", "(n::nat) <= n + m"),
  ("l6", "(a::int) + b = b + a"),
  ("l7", "(n::nat) - n = 0"),
  ("n1", "(a::int) * a >= a"),
  ("n5", "(n::nat) * m = m * n"),
  ("n6", "(a::int) * a >= 0"),
  ("n8", "(n::nat) <= n * n + 1"),
  ("ls5", "rev (rev xs) = xs"),
  ("ls6", "length (xs @ ys) = length xs + length ys"),
  ("ls7", "set (rev xs) = set xs"),
  ("o4", "map_option f (Some a) = Some (f a)"),
  ("o5", "fst (a, b) = a"),
  ("o7", "Inl a ~= Inr b"),
  ("s3", "A \<inter> B \<subseteq> (A::'a set)"),
  ("s4", "A \<union> B = B \<union> (A::'a set)"),
  ("s6", "x \<in> insert x (A::'a set)"),
  ("q2", "\<forall>n::nat. \<exists>m. n < m"),
  ("q4", "\<forall>n::nat. n = 0 | (\<exists>m. n = Suc m)"),
  ("q6", "\<forall>xs::nat list. sorted (sort xs)"),
  ("e2", "\<exists>xs::nat list. \<forall>a. a \<in> set xs --> a = 0"),
  ("e4", "\<exists>n::nat. \<forall>m::nat. n <= m"),
  ("e6", "\<exists>f::nat=>nat. \<forall>n. f n <= n"),
  ("h3", "map f (map g (xs::'a list)) = map (f o g) xs"),
  ("h4", "(%x::'a. f x) = f"),
  ("h6", "inj (%n::nat. Suc n)"),
  ("h8", "surj (%n::nat. n)")
];

val tactics : (string * (Proof.context -> tactic)) list = [
  ("auto", fn c => Clasimp.auto_tac c),
  ("fastforce", fn c => HEADGOAL (Clasimp.fast_force_tac c)),
  ("arith", fn c => HEADGOAL (Arith_Data.arith_tac c)),
  ("blast", fn c => HEADGOAL (Blast.blast_tac c)),
  ("presburger", fn c => HEADGOAL (Cooper.tac true [] [] c))
];

fun try_prove t (name, tac) =
  (case try (fn () =>
      Timeout.apply (Time.fromSeconds 10) (fn () =>
        Goal.prove ctxt0 [] [] t (fn {context, ...} => tac context)) ()) () of
    SOME _ => SOME name
  | NONE => NONE);

fun one (id, s) =
  let
    val t = Syntax.read_prop ctxt0 s;
    val res = get_first (try_prove t) tactics;
  in writeln ("TRUTH\t" ^ id ^ "\t" ^ (case res of SOME n => n | NONE => "UNPROVED")) end;

val _ = List.app one true_goals;
val _ = writeln "TRUTH_DONE";
