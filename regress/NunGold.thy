theory NunGold
  imports "HOL.Nunchaku"
begin

(* Gold smoke test for the shipping configuration (solvers = "cvc5 smbc",
   timeout = 1).  Run after every rebuild, before anything else.  Asserts:
     1. the false goal is refuted with verdict "genuine";
     2. the model is actually displayed (SOME model -- catches the smbc
        model-hole regression, where one unparsable hole loses the whole
        model: "Model unavailable due to internal error");
     3. wall clock stays within a generous cap (catches timeout-handling
        regressions, where a 1 s budget silently becomes 0 or unbounded);
     4. negative control: a true goal must NOT be refuted.
   Loading this theory raises on any failure; on success it prints GOLD_OK. *)

ML \<open>
local
  val thy = \<^theory>;
  val state0 = Proof.init (Proof_Context.init_global thy);
  val params = Nunchaku_Commands.default_params thy
    [("timeout", "1"), ("solvers", "cvc5 smbc")];
  fun run prop_str =
    let
      val t = Syntax.read_prop (Proof_Context.init_global thy) prop_str;
      val ({elapsed, ...}, (verdict, model_opt)) =
        Timing.timing (fn () => Nunchaku.run_chaku_on_prop state0 params Nunchaku.Normal 1 [] t) ();
    in (verdict, model_opt, elapsed) end;
in
val _ =
  let
    val (verdict, model_opt, elapsed) = run "hd (xs @ ys) = hd xs";
    val _ = verdict = Nunchaku.genuineN orelse
      error ("GOLD FAIL: expected genuine, got " ^ quote verdict);
    val _ = is_some model_opt orelse
      error "GOLD FAIL: counterexample found but model not displayed";
    val _ = elapsed < Time.fromSeconds 10 orelse
      error ("GOLD FAIL: took " ^ Time.toString elapsed ^ " s");
    val (verdict_neg, _, _) = run "rev (rev xs) = xs";
    val _ =
      if verdict_neg = Nunchaku.genuineN orelse verdict_neg = Nunchaku.quasi_genuineN
      then error "GOLD FAIL: true goal refuted (misrefutation)"
      else ();
  in writeln "GOLD_OK" end;
end
\<close>

end
