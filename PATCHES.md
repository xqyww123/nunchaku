# Patches this fork carries

Policy: the fork no longer upstreams.  The submissions to
`nunchaku-inria/nunchaku` were withdrawn, so this file is the only record
of what the fork carries and why; it is written to be readable by someone
who has never seen the upstream repository.  Base commit: d23a876.

## 1. Fractional `--timeout` (`a1828aa`)

- **Motivation**: the scheduler deadline is a float, but `--timeout` was
  `Arg.Set_int`, so sub-second budgets were inexpressible: a caller
  passing `0.3` failed to parse, and a frontend truncating to `0` got a
  deadline equal to the start instant — every run answered UNKNOWN.
  1 s is the smallest expressible budget and exactly the operating point
  of fast-guard consumers.
- **Repro**: `nunchaku --solvers smbc --timeout 0.7 <any sat problem>`;
  before: `wrong argument '0.7'`; after: SAT in milliseconds.  Integer
  arguments behave as before.

## 2. String literals in the sexp lexer (`930d1c7`)

- **Motivation**: backends can emit strings — cvc5 answers
  `(error "...")` to an unsupported command — and `Sexp_lex` had no
  string rule, so the first `"` crashed the lexer instead of letting the
  model parser fail cleanly (this is how a cvc5-version mismatch escalated
  into a crash).
- **Repro**: run with a cvc5 < 1.3.1 (which lacks
  `get-model-domain-elements`) on a problem with datatypes; before:
  `lexer error ... lexing failed on char "`; after: a clean
  `expected model` error.

## 3. `NUNCHAKU_CVC5` / `NUNCHAKU_SMBC`; loud unavailable-solver handling (`c63de1b`)

- **Motivation**: backend binaries were located exclusively via PATH
  (`exec cvc5`, `which cvc5`), so a wrapper could only steer which binary
  runs by PATH-prepending, and every failure mode of that arrangement is
  silent.  Separately, solvers requested by an explicit `--solvers` but
  unavailable were silently dropped from the schedule, so a broken
  installation just looked weak.
- **Behavior**: `NUNCHAKU_CVC5`/`NUNCHAKU_SMBC`, when set and non-empty,
  name the binary directly (used both for invocation and availability
  checks); unset, nothing changes.  A requested-but-unavailable solver
  warns on stderr; when no requested solver is available the error names
  them all and the exit code is non-zero (as before).
- **Deviation from the original plan, recorded**: the plan asked for a
  non-zero exit whenever any explicitly requested solver is unavailable.
  Measured reality: the Isabelle frontend always requests
  `cvc5 kodkod paradox smbc`, and no Isabelle distribution ships paradox —
  literal hard-fail semantics would kill every stock invocation.  Warnings
  plus the existing all-unavailable failure keep the intent (a broken
  installation is visible) without breaking stock users.

## 4. Parseable identities for smbc model unknowns (`8719aca`)

- **Motivation**: smbc models can contain unknowns (`?list__3`-style
  constants).  They were wrapped in `` `Undefined_self ``, printing as
  `?__ ?list__3` — not part of the model grammar consumers know.  The
  Isabelle frontend accepts only `?__<int>` holes and parses the model
  block as a whole, so one such hole loses the entire model
  ("Model unavailable due to internal error"; 23 of 78 benchmark goals).
  The wrapping site carries upstream's own FIXME.
- **Fix**: thread the expected type down through `term_of_tip` (from the
  model entry's defined symbol, through argument positions by unfolding
  the head's type — smbc problems are monomorphic, so no unification —
  and through match/if/let/prop positions).  A typed unknown becomes
  `` `Undefined_atom `` with its freshly allocated (collision-free by
  construction) id, printing as `?__<n>`; with no type at hand the old
  opaque hole is kept, so uncovered positions behave exactly as before.
  Accepted loss: the unknown's own name is no longer displayed
  (consumers render an "irrelevant" placeholder) — strictly better than
  losing the whole model.
- **Repro**: `nunchaku --solvers smbc` on
  `goal ~ (hd_ (append_ xs_ ys_) = hd_ xs_)` over a `list_` datatype;
  before: `val ys_ := Cons_ $a__0 (?__ ?list__3).`; after:
  `val ys_ := Cons_ $a__0 ?__117.`
- **Follow-up (adversarial review round)**: the expected-type recovery was
  completed after review found reachable gaps -- head-position unknowns
  (any goal with a free function variable; the HO_app case now carries
  expectations through smbc's `(fun x. ...) arg` redexes), domain elements
  registered into the typing env by a pre-scan, symmetric Eq/Distinct,
  match scrutinees recovered from branch constructors, and repeated
  unknowns sharing one `?__<n>` (the erase-table lookup preceded the `?`
  test, a pre-existing upstream defect).


## 5. `--version` placeholder never expanded (`src/main/dune`)

- **Motivation**: the `Const.ml` generation rule echoes `${version:nunchaku}`
  literally — dune 2 variables are `%{...}` — so `--version` has printed the
  raw placeholder since the dune 2 migration.  Cosmetic for the Isabelle
  frontend (it never calls `--version`), but release hygiene: the CI smoke
  asserts the placeholder is gone.
- **Repro**: `nunchaku --version`; before:
  `nunchaku ${version:nunchaku} <sha>`; after: `nunchaku 0.6 <sha>`
  (dev checkout) / the tag version (released build, via `dune subst`).

## 6. Spurious-model soundness for incomplete copy encodings

- **Motivation**: `ElimCopy` encodes an infinite-carrier copy type
  (Isabelle's `int` arrives as a `partial_quotient` over `nat × nat`)
  as an uninterpreted type WITHOUT the defining axiom (`ax_defined` is
  dropped when the carrier has no small exact cardinality), leaving
  `abstract`/`concrete` underconstrained -- a backend can pick an
  interpretation under which the copied operations misevaluate.
  Witnessed: smbc "refuting" the true goal `(a::int) * a >= a` with
  `a = 0` in 115 ms (caught by the regression gate's SPURIOUS rule on
  the first certification of the shipping configuration).  Upstream
  set only `unsat_means_unknown` for these encodings, and the model
  flag `potentially_spurious` had no producer anywhere in the tree.
- **Fix**: `ElimCopy` also sets `sat_means_unknown` for both incomplete
  copy encodings (subset and quotient); the smbc backend surfaces the
  problem metadata on returned models (`potentially_spurious`), so the
  binary prints `SAT: (potentially spurious)`.  New CLI flag
  `--no-spurious-models` reports UNKNOWN instead -- for consumers that
  classify on the first output token and never see the marker (the
  stock Isabelle frontend does exactly that).  The shipped component's
  wrapper passes the flag.
- **Repro**: the captured frontend problem for `(a::int) * a >= a` with
  `--solvers smbc`; before: `SAT: { val a_ := Abs_Integ_ (Pair_ (Suc_
  zero_) (Suc_ zero_)). }` reported as a genuine countermodel; after:
  `SAT: (potentially spurious)` by default, `UNKNOWN` under the flag.
- **Superseded in part by §7**, which is where this patch's shape lives
  today: the marking left the smbc backend for one pipeline stage that every
  backend goes through, and suppression became the default -- so the repro
  above now ends the other way round, `UNKNOWN` by default and
  `SAT: (potentially spurious)` under `--allow-spurious-models`.  What
  survives here unchanged is where it all starts: `ElimCopy` setting
  `sat_means_unknown` on an incomplete copy encoding.

## 7. One home for the spurious-model policy (soundness batch)

- **Motivation**: patch 6 marked models, but only in the smbc backend, and
  only the marking.  Three holes remained.  (i) The mark was per-backend:
  cvc5 and kodkod never set it, so on the eight real Isabelle goals that
  carry `sat_means_unknown` (all `int` goals: `l3 l6 n1 n2 n4 n6 e7`
  of `regress/bench.ML`, `b3` of `bench2.ML`) whichever backend won the
  race decided whether the answer was marked -- measured on the captured
  frontend problems, `--solvers cvc5,kodkod` returned a bare `SAT` on
  `n4` and `b3` even with `--no-spurious-models` on, which the Isabelle
  frontend (`nunchaku_tool.ML`, `String.isPrefix "SAT"`) files as a
  genuine countermodel.  (ii) The `unsat_means_unknown` rewrite was
  copy-pasted into four backends and missing from the fifth: `Kodkod.ml`
  never mentions the metadata at all, so an `unsat` from kodkod on a
  problem whose encoding lost models was reported as a refutation.
  (iii) Suppression was off by default, so the safety of every published
  binary rested on one line of one bash wrapper that is not shipped with
  it.
- **Fix**: a new transformation `Mark_spurious` (`src/transformations/`)
  captures the problem metadata at encode and rewrites the result at
  decode -- `sat_means_unknown` marks the model `potentially_spurious`,
  `unsat_means_unknown` turns `Unsat` into `Unknown [U_incomplete]`.
  `close_task` (`src/main/Close_task.ml`) composes it itself, so no branch
  of the pipeline can omit it and no backend has to remember it; the four
  per-backend `unsat` guards and smbc's model-marking merge are deleted.
  Two properties make that site the only correct one: the stage runs
  after the whole decode chain, so kodkod's model -- rebuilt from
  `Model.empty` by `FoToRelational` -- still gets the mark; and
  `Kodkod.ml` stays untouched, which matters because its bound-increment
  loop re-matches on `Res.Unsat` and would silently stop growing the
  bound if `solve` started returning `Unknown`.  Closing a pipeline is what
  builds a task, so a second closer anywhere would be a second policy: the
  closer therefore lives alone in `Close_task.ml`, and a `dune runtest` rule
  requires it to appear there exactly once and in `nunchaku.ml` never --
  which is a grep because `Transform` lives in the `core` library and cannot
  hide a value from its own users, and it looks for the unqualified spelling
  too, since every pipeline builder in `nunchaku.ml` opens `Transform.Pipe`.
- **Shortcut demotion, and its limits**: a task's post-processing now
  decides the result and the scheduler's shortcut together
  (`Scheduling.Task.post` takes and returns the pair; `Task.map` is
  preserved as the shortcut-keeping special case of the new
  `Task.map_res`).  A rewritten `unsat` no longer ends the race, so a
  sibling backend may still conclude -- not hypothetical: `e3` and `e6`
  carry `unsat_means_unknown` in the cvc5/kodkod encoding branch and not
  in the smbc one.  Deliberately *not* demoted: a potentially spurious
  `Sat` (`sat_means_unknown` is a property of the problem, so every
  sibling's `Sat` would be marked too; measured price of demoting it is
  the caller's whole timeout budget on 4 of 6 marked goals, with no
  verdict change in 12 of 12 paired runs), and an `Error` (it would put
  a non-`Unknown` into the scheduler's result list, which `process_res_`
  rejects).  The rule at that one point runs both ways: an `unknown` never
  keeps a shortcut, and only an `unknown` can lose one.  The first half is
  wider than the rewrite that motivates it -- a backend that asked to
  shortcut on an `unknown` is overruled without being told.  No backend does
  that today (every `unknown` any of them returns already carries
  `No_shortcut`), and an inconclusive answer has no business ending the race
  whoever asked for it, which is why the rule is stated where it is enforced
  rather than left to five backends to observe.
- **The two directions are deliberately asymmetric.**  A suppressed model
  can be seen again with `--allow-spurious-models`; an `unsat` under
  `unsat_means_unknown` becomes `UNKNOWN` unconditionally, with no switch to
  get the original answer back.  That is soundness first, and a decision
  rather than an oversight: a potentially spurious model is still an object
  a user can inspect and judge, whereas the answer being withheld in the
  other direction is the bare word `unsat`, which carries nothing to judge.
  If symmetry is ever wanted, it is a new flag, not a bug fix.
- **Reporting**: new `Res.U_potentially_spurious`, printed
  `POTENTIALLY_SPURIOUS`, replaces the `U_other` the suppression used to
  emit -- the two soundness directions are now distinguishable by tag
  (`INCOMPLETE` = models were lost, so an `unsat` claims nothing;
  `POTENTIALLY_SPURIOUS` = a model was found but may not be one).
  `U_other` itself now prints `OTHER` instead of `INCOMPLETE`, which it
  never was (it carries the `--dump` paths and smbc's own "unknown").
  Suppression stays where it was, before the `-o sexp` / `-o tptp`
  dispatch, so those inherit it.
- **Flag family**: `--no-spurious-models` is now the default and is kept
  as an accepted no-op (an unknown option exits 2, and every shipped
  wrapper passes it); `--allow-spurious-models` is the way back to a
  printed model.  The component wrapper keeps passing the old flag on
  purpose, so the component does not depend on the binary's default.
- **Also here**: the comment explaining why `ElimCopy` sets
  `sat_means_unknown` was wrong in both halves (it named `concrete` as
  the loose function and the abstract type's image as the loose region);
  it now says that `abstract` is pinned only on the image of `concrete`
  and may land in an unrelated class anywhere else.  The two `assert`s in
  `process_res_` became one `Utils.failwithf` naming the offending
  constructor, since that invariant is now enforced by `close_task` and a
  violation used to reach the user as a bare `Assertion failed`.
- **Repro**: captured frontend problem for `n4`,
  `--solvers cvc5,kodkod --timeout 5`; before: `SAT: ...` (unmarked, with
  the wrapper's flag on); after: `UNKNOWN (POTENTIALLY_SPURIOUS ...)`, and
  `SAT: (potentially spurious) {...}` under `--allow-spurious-models`.
  Unaffected: `regress/gold.nun` still prints an unmarked `SAT: {`.

## 8. One failing backend no longer discards the other backends' answers

- **Motivation**: `Scheduling.run_pool` treated any exception escaping a
  task as the failure of the whole pool: it set the pool's state to
  `Res_fail`, which kills the still-running tasks and throws away the
  results already collected.  The exit code is 1 and the Isabelle
  frontend files that as `Unknown_Error`.  This is reachable from any
  backend -- the witnessed one is paradox, whose `parse_model` reports a
  parse failure by raising inside the task rather than by returning
  `Res.Error`, so no amount of result-level policy can catch it.
  Measured with a canned paradox reply that the parser rejects:
  `--solvers cvc5,smbc,paradox` on a problem cvc5 and smbc both refute
  returned `Error: ... exit=1` in 2 of 3 runs -- decided by whether
  paradox happened to finish first.
- **Fix**: a task that raises is recorded, not fatal.  `Res_list` now
  carries `('a list * exn list)`: the results of the tasks that did not
  end the race, and the exceptions of the tasks that produced no result.
  The run fails only when nobody produced anything at all.  A raise is
  never silently swallowed: when other tasks answered `unknown`, each
  exception is reported as a `BACKEND_ERROR` line of the final
  `UNKNOWN`.  An exception from a task's own post-processing (our decode
  chain, not the solver) still fails the run, as before.
- **Deliberate change of a documented test**: the qtest that pinned "a
  task that raises fails the pool" now pins the new semantics, and two
  qtests were added: nine answers plus one raise yield the nine answers
  and the exception; a raise loses to a sibling that shortcuts.
- **Where the isolation stops, deliberately**: an exception raised by a
  task's own post-processing still fails the run.  That post-processing is
  our decode chain rather than the solver's doing, so a crash in it is our
  bug and should be loud -- even though the data that provoked it came from
  an untrusted solver.  Worth revisiting if a decode-chain raise ever shows
  up in the field.
- **Repro**: `NUNCHAKU_PARADOX=<canned reply> nunchaku --solvers
  cvc5,smbc,paradox --timeout 5` on a refutable copy-free problem;
  before: `Error: Paradox: parsing model failed`, exit 1; after: `UNSAT`,
  exit 0, 3 runs out of 3.

## 9. `--timeout` is a wall-clock deadline, not a hint

- **Motivation**: nothing enforced `--timeout` in wall-clock time.  The
  pool waited on a condition variable with no deadline of its own, and the
  only hard limit anywhere was cvc5's `ulimit -t timeout+1.5`, which
  counts **CPU** seconds -- so a run that is not answered costs more than
  it was given: measured on a captured Isabelle `int` problem,
  `--solvers cvc5` took 7.05 s at `--timeout 5` and 5.57 s at
  `--timeout 1`.  The Isabelle frontend caps the call at `timeout + 1 s`
  and kills it from outside, so those overruns reached the user as
  "Time out" rather than as an answer, and the extra seconds were spent
  before the kill.
- **Fix**: `Scheduling.run` starts one thread that sleeps until the pool's
  deadline and wakes the pool (there is no timed `Condition.wait`).  At
  the deadline the pool stops its running tasks and returns what the
  finished ones produced.  If nothing was produced at all, the result is
  `UNKNOWN (TIMEOUT ...)` and exit 0 -- where the previous code would have
  reported `no task succeeded` with exit 1, which the Isabelle frontend
  files as `Unknown_Error`.  cvc5's `ulimit -t` stays as a CPU backstop;
  the wall clock is now the binding limit.
- **What a preempted backend loses**: a task killed at the deadline never
  reports, so its own diagnostic goes with it.  `--solvers kodkod
  --timeout 5` on a copy problem used to end with
  `TIMEOUT {backend:kodkod, …, message="dimension 8"}` -- the only clue how
  far kodkod got -- and now ends with `TIMEOUT {backend:scheduler, …}`.
  There is no grace window: the deadline is the deadline.  Buying the
  diagnostic back means letting a killed task report on its way out, which
  is worth doing when someone misses it.
- **Who decides that a run failed**: not the pool.  It reports the results
  it collected and the exceptions it caught, and `process_res_` reads that
  once: nothing but exceptions, one per task, is a broken installation and
  exits 1; an exception beside a timeout is a `BACKEND_ERROR` line under the
  `TIMEOUT` one, because a backend that died must not become invisible
  behind the clock.
- **Also**: the `Scheduling` qtests passed `~deadline:5.`, an absolute
  time in 1970, which only worked because nothing read the deadline; they
  now pass `Unix.gettimeofday () +. 5.`
- **Repro**: captured Isabelle problem for `n1`, `--solvers cvc5`; before:
  7.05 s at `--timeout 5`, 5.57 s at `--timeout 1`; after: 5.01 s and
  1.01 s, same verdict.
