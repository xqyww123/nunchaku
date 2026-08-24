theory NunGold
  imports "HOL.Nunchaku"
begin

(* Gold smoke test.  Run after every rebuild, before anything else.  Asserts:
     1. shipping configuration (solvers = "cvc5 smbc", timeout = 1): the
        false goal is refuted with verdict "genuine", the model is
        displayed, and wall clock stays within a generous cap (catches
        hangs before they cost a 30-minute benchmark run);
     2. smbc alone: the model is displayed -- this is the arm the smbc
        model-hole fixes live on; under the shipping configuration cvc5
        sometimes answers first, which would silently retire the assertion;
     3. negative control: a true goal must NOT be refuted.
   Loading this theory raises on any failure; on success it prints GOLD_OK. *)

ML \<open>
local
  val thy = \<^theory>;
  val state0 = Proof.init (Proof_Context.init_global thy);
  fun run solvers prop_str =
    let
      val params = Nunchaku_Commands.default_params thy
        [("timeout", "1"), ("solvers", solvers)];
      val t = Syntax.read_prop (Proof_Context.init_global thy) prop_str;
      val ({elapsed, ...}, (verdict, model_opt)) =
        Timing.timing (fn () => Nunchaku.run_chaku_on_prop state0 params Nunchaku.Normal 1 [] t) ();
    in (verdict, model_opt, elapsed) end;
in
val _ =
  let
    val (verdict, model_opt, elapsed) = run "cvc5 smbc" "hd (xs @ ys) = hd xs";
    val _ = verdict = Nunchaku.genuineN orelse
      error ("GOLD FAIL: expected genuine, got " ^ quote verdict);
    val _ = is_some model_opt orelse
      error "GOLD FAIL: counterexample found but model not displayed";
    val _ = elapsed < Time.fromSeconds 10 orelse
      error ("GOLD FAIL: took " ^ Time.toString elapsed ^ " s");
    val (verdict_smbc, model_smbc, _) = run "smbc" "hd (xs @ ys) = hd xs";
    val _ = verdict_smbc = Nunchaku.genuineN orelse
      error ("GOLD FAIL (smbc arm): expected genuine, got " ^ quote verdict_smbc);
    val _ = is_some model_smbc orelse
      error "GOLD FAIL (smbc arm): model not displayed (smbc model-hole regression)";
    val (verdict_neg, _, _) = run "cvc5 smbc" "rev (rev xs) = xs";
    val _ =
      if verdict_neg = Nunchaku.genuineN orelse verdict_neg = Nunchaku.quasi_genuineN
      then error "GOLD FAIL: true goal refuted (misrefutation)"
      else ();
  in writeln "GOLD_OK" end;
end
\<close>

end
