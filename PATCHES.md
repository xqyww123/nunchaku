# Patches this fork carries

This fork is maintained independently of `nunchaku-inria/nunchaku` and does not
submit its changes upstream.  This file is therefore the complete record of what
the fork changes and why, written so that a reader who has never seen the
upstream repository can follow it.  Each entry states the motivation, a
reproduction, and the fork commit that carries it.  Base commit: d23a876.

Reading the file: the entries are in landing order, so a later one can supersede
an earlier one; where that happened the earlier entry ends with a
"Superseded in part by §N" note, and §N is the entry that describes the current
shape of that change.  `(commit: TBD)` marks an entry whose work is written and
reviewed but which has not been cherry-picked onto the fork's `main` yet, so its
hash is not final; the hashes are filled in as the entries land, and until an
entry lands the fork's `main` still behaves as the entry it supersedes
describes.  A hash therefore means "on `main`" — not "in the shipped component",
which is built and certified separately.  The *component* is the bundle
Isabelle installs: a wrapper script that sets the solver environment variables
and execs the binary, plus the solvers it pins.  The project also publishes the
bare binary on its own, without that wrapper.  *Certified* means run through the
regression gate (see §6) and accepted against its checked-in baseline.

The tool it patches is a model finder: given a first-order problem it looks for a
model — for the Isabelle frontend, a countermodel to the goal — and answers `SAT`
(a model was found, so the goal is refuted), `UNSAT` (no model exists in the
search space) or `UNKNOWN`.  It answers by racing several external solver
backends (cvc5, CVC4, kodkod, paradox, smbc) against each other on the same
problem; each concurrent run is a *task*, the whole set of them is the *race*,
and the scheduler component that runs them is the *pool*.

## 1. Fractional `--timeout` (`a1828aa`)

- **Motivation**: the scheduler deadline is a float, but `--timeout` was
  `Arg.Set_int`, so sub-second budgets were inexpressible: a caller
  passing `0.3` failed to parse, and a frontend truncating to `0` got a
  deadline equal to the start instant.  1 s was therefore the smallest
  budget that could be expressed at all, and it is exactly the operating
  point of a *fast-guard consumer* — one that calls nunchaku as a quick
  counterexample check before spending time on a proof attempt, at
  sub-second budgets.  φ-System's proof automation is the consumer this
  fork was built for.
- **Repro**: `nunchaku --solvers smbc --timeout 0.7 <any sat problem>`;
  before: `wrong argument '0.7'`; after: SAT in milliseconds.  Integer
  arguments behave as before.
- **Scope**: this patch makes `--timeout` *accept* a fractional value and
  nothing more.  Making the pool honour that value as a wall-clock deadline
  is §19, and until §19 landed the budget was not enforced in wall-clock
  time at all.

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
- **Superseded in part by §9**, which replaced this single regexp rule with a
  scanning sub-rule; what survives here is the fact that the lexer accepts
  string literals at all.  §8 covers the other outcome of the same
  version mismatch: where the stale cvc5's reply does parse, it used to be
  miscounted into a fabricated model rather than rejected.

## 3. `NUNCHAKU_CVC5` / `NUNCHAKU_SMBC`; loud unavailable-solver handling (`c63de1b`)

- **Motivation**: backend binaries were located exclusively via PATH
  (`exec cvc5`, `which cvc5`), so a wrapper could only steer which binary
  runs by PATH-prepending, and every failure mode of that arrangement is
  silent.  Separately, solvers requested by an explicit `--solvers` but
  unavailable were silently dropped from the schedule, so a broken
  installation just looked weak.
- **Behavior**: `NUNCHAKU_CVC5`/`NUNCHAKU_SMBC`, when set and non-empty,
  name the binary directly (used both for invocation and availability
  checks); unset, nothing changes.  The funnel they go through reads one
  variable per backend, so the family is five in total (§11 lists them); this
  entry's title names the two that motivated it.
  A requested-but-unavailable solver
  warns on stderr; when no requested solver is available the error names
  them all and the exit code is non-zero (as before).
- **Deviation from the original plan, recorded**: the plan asked for a
  non-zero exit whenever any explicitly requested solver is unavailable.
  Measured reality: the Isabelle frontend always requests
  `cvc5 kodkod paradox smbc`, and no Isabelle distribution ships paradox —
  literal hard-fail semantics would kill every stock invocation.  Warnings
  plus the existing all-unavailable failure keep the intent (a broken
  installation is visible) without breaking stock users.
- **Superseded in part by §11 and §12**: the unavailable-solver line is now a
  framed `Utils.warningf` with its own toggle (§11); and a variable set to the
  *empty* string, which as this patch landed was read as "unset" and fell back
  to PATH, is now an error (§12).

## 4. Parseable identities for smbc model unknowns (`8719aca`)

- **Motivation**: smbc models can contain unknowns (`?list__3`-style
  constants — a hole *inside* a model, not the `UNKNOWN` verdict).  They were wrapped in `` `Undefined_self ``, printing as
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
- **Follow-up (adversarial review round)** (`57e6e64`): the expected-type recovery was
  completed after review found reachable gaps -- head-position unknowns
  (any goal with a free function variable; the HO_app case now carries
  expectations through smbc's `(fun x. ...) arg` redexes), domain elements
  registered into the typing env by a pre-scan, symmetric Eq/Distinct,
  match scrutinees recovered from branch constructors, and repeated
  unknowns sharing one `?__<n>` (the erase-table lookup preceded the `?`
  test, a pre-existing upstream defect).
- **Superseded in part by §15**: the shape the follow-up introduced -- convert
  a node, read the type off the result, convert it again with an expectation
  -- was replaced wholesale there.  Do not restore it.  What survives here is
  the typed hole itself, `?__<n>`, and the rule that an unknown with no type
  at hand keeps the old opaque form.


## 5. `--version` placeholder never expanded (`7933c3c`)

- **Motivation**: the `Const.ml` generation rule echoes `${version:nunchaku}`
  literally — dune 2 variables are `%{...}` — so `--version` has printed the
  raw placeholder since the dune 2 migration.  Cosmetic for the Isabelle
  frontend (it never calls `--version`), but release hygiene: the CI smoke
  asserts the placeholder is gone.
- **Repro**: `nunchaku --version`; before:
  `nunchaku ${version:nunchaku} <sha>`; after: `nunchaku 0.6 <sha>`
  (dev checkout) / the tag version (released build, via `dune subst`).

## 6. Spurious-model soundness for incomplete copy encodings (`5a8a037`)

- **Motivation**: `ElimCopy` encodes an infinite-carrier copy type
  (Isabelle's `int` arrives as a `partial_quotient` over `nat × nat`)
  as an uninterpreted type WITHOUT the defining axiom (`ax_defined` is
  dropped when the carrier has no small exact cardinality), leaving
  `abstract`/`concrete` underconstrained -- a backend can pick an
  interpretation under which the copied operations misevaluate.
  Witnessed: smbc "refuting" the true goal `(a::int) * a >= a` with
  `a = 0` in 115 ms (caught by the regression gate -- the Isabelle-driven
  benchmark under `regress/` whose per-goal verdicts are compared against a
  checked-in baseline before a release -- on the first such certification of
  the configuration that ships).  Upstream
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
- **Repro** (as this patch landed; §7 later reversed the default — read the
  note below before using it): the captured frontend problem for
  `(a::int) * a >= a` with `--solvers smbc`; before: `SAT: { val a_ :=
  Abs_Integ_ (Pair_ (Suc_ zero_) (Suc_ zero_)). }` reported as a genuine
  countermodel; after: `SAT: (potentially spurious)` by default, `UNKNOWN`
  under the flag.
- **Superseded in part by §7**, which is where this patch's shape lives
  today: the marking left the smbc backend for one pipeline stage that every
  backend goes through, and suppression became the default -- so the repro
  above now ends the other way round, `UNKNOWN` by default and
  `SAT: (potentially spurious)` under `--allow-spurious-models`.  What
  survives here unchanged is where it all starts: `ElimCopy` setting
  `sat_means_unknown` on an incomplete copy encoding.

## 7. One home for the spurious-model policy (soundness batch) (`7b3897f`)

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
  binary rested on one line of one bash wrapper -- the component wrapper,
  which the published bare binary does not carry.
- **Fix**: a new transformation `Mark_spurious` (`src/transformations/`)
  captures the problem metadata at encode and rewrites the result at
  decode -- `sat_means_unknown` marks the model `potentially_spurious`,
  `unsat_means_unknown` turns `Unsat` into `Unknown [U_incomplete]`.
  (Three spellings, one idea, as with the backend error in §8:
  `sat_means_unknown` is the flag on the *problem*, `potentially_spurious` the
  flag on the *model* it produced, `POTENTIALLY_SPURIOUS` the word printed.)
  `close_task` (`src/main/Close_task.ml`) composes it itself, so no branch
  of the pipeline can omit it and no backend has to remember it; the four
  per-backend `unsat` guards and smbc's model-marking merge are deleted.
  Two properties make that site the only correct one: the stage runs
  after the whole decode chain, so kodkod's model -- rebuilt from
  `Model.empty` by `FoToRelational` -- still gets the mark; and
  `Kodkod.ml` stays untouched, which matters because its bound-increment
  loop re-matches on `Res.Unsat` to decide whether to retry with a bigger
  universe (it grows the bound on an `unsat` unless the universe is already
  at a deduced maximum cardinality), and would silently stop growing the
  bound if `solve` started returning `Unknown`.  Closing a pipeline is what
  builds a task, so a second closer anywhere would be a second policy: the
  closer therefore lives alone in `Close_task.ml`, and a `dune runtest` rule
  requires the pipeline closer `Transform.Pipe.close` to appear there
  exactly once and in `nunchaku.ml` never --
  which is a grep because `Transform` lives in the `core` library and cannot
  hide a value from its own users, and it looks for the unqualified spelling
  too, since every pipeline builder in `nunchaku.ml` opens `Transform.Pipe`.
- **Which goals carry `sat_means_unknown`**: that flag -- the SAT direction,
  the one this entry is named for -- is set by `ElimCopy`, i.e. by how the
  frontend spells the type, not by what the goal says.  A copy type reaches
  `ElimCopy` in one of three shapes: a *plain* copy, which is a bijection and
  is never marked; a *subset* copy; and a *quotient* copy, spelled
  `partial_quotient` in the problem file.  The latter two are marked when the
  carrier has no small exact cardinality.  Isabelle emits
  `'a set` as a plain copy (`abstract Collect_`) and `int` as a partial
  quotient, so `int` is marked and `set` is not.  Over the 79 captured
  problems of the certified benchmark -- the 78 goals of `bench.ML` (57) and
  `bench2.ML` (21), plus the `gold.nun` smoke problem, which is why the count
  here is one more than the 78 of §4 -- exactly the eight `int` goals above
  carry `sat_means_unknown`, in both encoding branches -- the pipeline
  encodes a problem differently for the cvc5/CVC4/kodkod/paradox family than
  for smbc, and the two branches can disagree about these flags -- and no
  `set` goal carries it.  The UNSAT direction is a different flag with a
  different population: `unsat_means_unknown` says the encoding *lost* models,
  which any model-losing approximation can cause, not `ElimCopy` alone.  In
  the same benchmark it is set on `e3`, `e6` and `e7` in the cvc5/kodkod
  branch and on `e7` only in the smbc one.
- **Shortcut demotion, and its limits**: each finished task hands the
  scheduler its result together with a *shortcut* flag -- `Shortcut` means
  "this answer ends the race, stop the siblings", `No_shortcut` means
  "record it and let the others run".  A task's post-processing now
  decides the result and that flag together
  (`Scheduling.Task.post` takes and returns the pair; `Task.map` is
  preserved as the shortcut-keeping special case of the new
  `Task.map_res`).  Call that one place -- where a finished task's result
  and its shortcut are settled together -- **the merge point**.
  A rewritten `unsat` no longer ends the
  race, so a sibling backend may still conclude -- not hypothetical: `e3`
  and `e6` carry `unsat_means_unknown` in the cvc5/kodkod encoding branch
  and not in the smbc one.  Deliberately *not* demoted: a potentially
  spurious `Sat` (`sat_means_unknown` is a property of the problem, so every
  sibling's `Sat` would be marked too; measured price of demoting it is
  the caller's whole timeout budget on 4 of the 6 marked goals that produce
  a model at all -- the other two of the eight answer `UNKNOWN` either way --
  with the verdict identical in all 12 of those runs, six goals run both
  ways), and an `Error` (it would put
  a non-`Unknown` into the scheduler's result list, which `process_res_`
  rejects).  The rule at the merge point runs both ways: an `unknown` never
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
  Paradox keeps its own short-circuit on the *problem's*
  `sat_means_unknown` flag -- it never set the model flag §6 speaks of, and
  still does not.  Deleting the short-circuit
  is deferred on two counts.  `Paradox.parse_model` fails by raising inside
  the task, which used to kill the whole race, so the deletion is not safe
  before §18; and no positive control for that parser exists yet, so a
  failure on a copy problem cannot be told apart from a bogus canned model.
  Its tag, though, is retagged to the same new constructor; it used to report `U_timeout`,
  which was not a timeout, and which the Isabelle frontend classified as one
  because it tests for the substring `TIMEOUT` before the `UNKNOWN` prefix.
  Isabelle maps its `Timeout` and its `Unknown` outcome to the same verdict,
  so no Isabelle verdict moves; a consumer that distinguishes the two will
  see the change.  Paradox fires on the same condition as the stage does, so
  the word means the same thing whichever backend printed it.
  `U_other` itself now prints `OTHER` instead of `INCOMPLETE`, which it
  never was (it carries the `--dump` paths and smbc's own "unknown").
  Suppression stays where it was, before the `-o sexp` / `-o tptp`
  dispatch, so those inherit it.
- **Flag family**: suppression is now the default.  `--no-spurious-models` is
  kept as an accepted no-op (an unknown option exits 2, and the shipped
  wrapper `component/x86_64-linux/nunchaku` passes it);
  `--allow-spurious-models`, on the binary's own command line, is the way
  back to a printed model.  The wrapper keeps passing the old flag on
  purpose: against this binary it does nothing, but it keeps the component
  suppressing spurious models even if it is ever pointed at a binary whose
  default is not suppression -- the component does not depend on that
  default.
- **Also here**: the comment explaining why `ElimCopy` sets
  `sat_means_unknown` was wrong in both halves (it named `concrete` as
  the loose function and the abstract type's image as the loose region);
  it now says that `abstract` is pinned only on the image of `concrete`
  and may land in an unrelated class anywhere else.  (§6's prose, which names
  the pair without saying which half is loose, is not wrong; the source
  comment named the wrong one of the two.)  The two `assert`s in
  `process_res_` became one `Utils.failwithf` naming the offending
  constructor, since that invariant is now enforced by `close_task` and a
  violation used to reach the user as a bare `Assertion failed`.
- **Repro**: captured frontend problem for `n4`,
  `--solvers cvc5,kodkod --timeout 5`; before: `SAT: ...` (unmarked, with
  the wrapper's flag on); after: `UNKNOWN (POTENTIALLY_SPURIOUS ...)`, and
  `SAT: (potentially spurious) {...}` under `--allow-spurious-models`.
  Unaffected: `regress/gold.nun` still prints an unmarked `SAT: {`.
- **Certification status at the time of writing**: this batch was re-run
  twice against the certification harness on the maintainer's machine.  The
  only verdict changes that reproduced in both runs are the false goals `n4`
  and `b3` losing refutations that the baseline itself records as
  undisplayable (`model=no`) -- which is precisely the intended effect of the
  marking, and the shape the acceptance rule was written to expect.  Other
  cells that differed between the two runs, including nitpick-arm cells that
  this fork does not touch at all, are machine timing noise.  A control run
  with the pristine base binary is in flight, to attribute an observed
  slowdown in the smbc arm.

## 8. Strict parsing of cvc5's finite-domain reply (commit: TBD)

- **Motivation**: `get_finite_domain_` read the answer to
  `get-model-domain-elements` as "however many elements this list has",
  so a cvc5 that does not implement the command (< 1.3.1 answers
  `(error "Parse Error: ...")`) produced a two-element domain and a
  model built from names cvc5 never used.  The domain was then
  enumerated by an index counter, `@<ty>_0 … @<ty>_<n-1>`, which is a
  guess at cvc5's naming rather than a reading of its answer.
- **Behavior**: only `(as NAME TY)` at the expected TY is a domain
  element; a top-level atom, an `(error …)` reply (echoed verbatim), an
  empty domain, repeated names, and a name that collides with a symbol
  of the problem are each rejected with their own message.  Every
  rejection — and, by the same one-line change in each of `Cvc5.ml` and
  `CVC4.ml`, the one arm where the result reader hands back a sexp-decoding
  failure —
  raises `Backend_err`, the fork's exception for "the solver sent something
  we cannot use".  (That arm only; the rest of the decoder is §13.)  A `Backend_err` becomes the result tag `U_backend_error`,
  which prints as `UNKNOWN (BACKEND_ERROR …)` and exits 0, with the sibling
  backends untouched; it is never a fatal
  `Error`.  (Three spellings, one idea: `Backend_err` the exception,
  `U_backend_error` the result tag, `BACKEND_ERROR` the printed word.)
  The rule is written next to the two exception definitions:
  `Error` is for nunchaku's own broken invariants, anything the solver
  sends that we cannot understand is `Backend_err`.  This entry makes the
  rule true of the domain reply; §13 makes it true of the rest of the
  decoder, which is where the get-value reply is read.
- **Repro**: `NUNCHAKU_CVC5=<cvc5 1.2.0> nunchaku --solvers cvc5 -j 1`
  (`-j 1` runs one backend at a time, which is what makes the output
  deterministic enough to compare)
  on a problem needing three distinct elements of an uninterpreted
  type; before: `SAT: { type a_ := {$a__0, $a__1}. val z_ := @a___2. }`
  — a model with two elements for a goal that needs three, and a value
  outside the domain it just printed; after:
  `` `UNKNOWN (BACKEND_ERROR … cvc5 rejected `get-model-domain-elements` …)` ``,
  exit 0.
- **The TY comparison does not use `pp_gty`**.  TY is a *ground type*, a type
  with no variables left in it; `a_` is a base one, `to_ a_ b_` a compound
  one.  The comparison has to decide whether the sort cvc5 echoed back is the
  one we declared, so it prints the expected type and compares.  `pp_gty`
  mangles every non-alphanumeric character and flattens application to
  `_to__a__b__`, where cvc5 echoes the sort as it was declared,
  `(to_ a_ b_)` — a list, not an atom.  The comparison uses the new
  `sexp_of_gty` instead, a wrapper over the shared `sexp_of_gty_` described
  three bullets down.  Measured over the 200 in-tree
  `.nun` problems under cvc5 1.3.4 with `-j 1`: 18 have a compound
  witness sort, and comparing against `pp_gty` rejects a correct reply
  on every one of them (SAT becomes UNKNOWN); one further problem has a
  base sort, `G_Suc-as-fun_`, whose name `pp_gty` mangles.  The new
  `sexp_of_gty` reproduces the declaration spelling structurally, and
  over the same 200 problems no verdict changes.
- **The models for those compound-sort problems do change, in the
  direction the patch is for**: the old code enumerated the domain by
  index, `@<pp_gty ty>_<i>`, which for a compound sort is a name cvc5
  never used, so the domain got freshly allocated ids unrelated to the
  ones in the model body — and the body kept printing cvc5's internal
  token, e.g. `?__184 |@(to_ a_ Bool)_0| v`.  Reading the names out of
  the reply makes the two coincide, so those constants now appear as
  ordinary model entries (`val $$anon_fun_0 := (fun …)`) and the id
  counter shifts.
- **The `pp_gty` comparison also failed fatally on one problem** when it was
  measured: `bench/bugs/ho_copy_set2.nun` gave an uncaught
  `Nunchaku_core.FO.Env.UndefinedID`, rc=1 with empty stdout.  That is a
  property of the rejected variant, not of the previous behaviour —
  before this patch the same problem answers `SAT` with a model.  Whether it
  is one of the 18 above or a further problem is not recorded.  (§13's
  catch-all landed after that measurement, so how loudly the rejected
  variant would fail today is not what was measured; the wrong rejection is
  the point either way.)
- **The comparison is tied to the declaration by construction**, not by
  inspection: `pp_ty` in the problem printer and the domain parser's
  expected type both go through one description of how a ground type is
  spelled, `sexp_of_gty_`, parameterised by how an id is named — the printer
  may register a name, the comparison refuses to.  Their agreement is what the
  paragraph above rests on, so it must not be something a future edit can
  break silently; the compound-sort case in `regress/cvc5_guard` is the
  test that would catch it if it did.
- **CVC4 is not affected and must not be "completed" later**: its
  `get_finite_domain_` reads an explicitly declared cardinal —
  `fmf.card.val`, parsed by `parse_int_` — not a list length.
  There is no counting defect there to port a fix to.  Only the reply
  classification touches `CVC4.ml`.
- **The written specification named the wrong table**, and review caught
  it: the collision guard was specified against `decode.symbols`, which
  holds the symbols we asked cvc5 for a *value* for.  A reply naming any
  other name we had declared — the type's own sort, `(as a__ a__)` —
  therefore passed the guard and fabricated a model whose
  `val x_ := @a___0` lies outside the domain the same model prints.  The
  test that is implemented is `decode.id_to_name`, which is exactly "a
  name we declared to cvc5".

## 9. String literals scanned by a lexer sub-rule (commit: TBD)

- **Motivation**: `Sexp_lex` matched a string literal as one regexp
  lexeme and counted its newlines afterwards, so no error could name a
  position *inside* a literal: while the opening quote is the current
  lexeme, that is the only position the lexer has.  An additive rule
  reports an illegal byte at `line 1, col 3 to 4` when the byte is at
  line 2, column 7.  Separately, the body class accepted every byte
  except the quote, so a C0 control smuggled through a backend's error
  message reached the user's terminal raw.
- **Behavior**: the body is scanned in a sub-rule with branches for the
  doubled quote, the closing quote, a newline (counted as it is
  passed), a run of body characters, end of input and an illegal byte.
  The body class is printable characters, tab, CR and bytes >= 0x80, so
  UTF-8 still lexes and the C0 controls and DEL do not.  End of input
  returns an option rather than raising, so the caller — the only place
  that still knows where the literal began — restores `lex_start_p` and
  an unterminated literal spans the whole literal.
  `unescape_state`, `char_equal` and `count_newlines` are gone.
- **Repro** (both shapes in the *domain* answer): a reply carrying
  `(a "l1\nl2 tail<ESC>x")`; before:
  the ESC byte reaches stdout verbatim; after:
  `line 2, col 7 to 8: illegal character 0x1b in string literal`, exit 0.  A
  reply cut off mid-literal in the *domain* answer: before,
  `Error: in the interface to cvc5: … lexing failed on char "` and the run
  aborts; after, `line 1, col 7 to line 2, col 7: unterminated string
  literal` and exit 0.  Both of those are exit 0 because §8 had already made
  the domain reply non-fatal; the same two shapes in the *get-value* answer
  were still fatal until §13 (see its table).
- **The tightening is only safe together with §13**: a strict lexer
  whose every complaint is fatal would be a reliability regression.
  §8 covered the domain reply only, and until §13 the tightened
  class *created* a fatal that fork `main` did not have — an escape byte in
  a get-value string is `SAT` with the byte in the model on `main`, and was
  an abort here.

## 10. Unquoting a backend's error message for display (commit: TBD)

- **Motivation**: a string literal reaches the model layer as its raw
  lexeme — delimiters kept and inner quotes still doubled — so cvc5
  answering `(error "has ""doubled"" quotes")` printed
  `BACKEND_ERROR {…} "has ""doubled"" quotes"`.
- **Behavior**: `Sexp_lib.unquote_atom` undoes the convention, in the
  module that created it, and is called at the two places that display
  a payload (`Cvc5.ml`, `CVC4.ml`) and nowhere else.  Atoms stay
  wire-faithful everywhere else, and §8's guard keeps echoing raw
  replies by construction, because it formats a `Sexp_lib.t` and never
  an atom payload.
- **Repro**: a cvc5 answering `(error "has ""doubled"" quotes")` where the
  backend *displays the payload*; before, the message carries the lexeme as
  it arrived, delimiters and doubled quotes included; after, the same message
  carries the delimiters stripped and each `""` collapsed to one `"`.  §8's
  domain guard is a different line and is unchanged: it echoes the reply as a
  `Sexp_lib.t`, never as an atom payload.
- **The alternative is dead, not merely unchosen**: unescaping inside
  the lexer would destroy both that echo and the ability to tell an
  atom from a string — which is exactly what §8's
  `` `List (`Atom "error" :: _) `` match depends on.  Nobody should
  revive it.

## 11. Which binary a backend chose, and the unavailable-solver warning (commit: TBD)

- **Motivation**: with `NUNCHAKU_*` overriding a PATH lookup there was
  no way to ask from the outside which binary a run actually used; and
  the aggregated unavailable-solver line was a bare `Format.eprintf`
  with no toggle and none of the framing every other warning gets.
- **Behavior**: one `Utils.debugf` in `Utils.external_program`, the
  funnel all five backends share — one variable per backend,
  `NUNCHAKU_CVC5`, `NUNCHAKU_CVC4`, `NUNCHAKU_KODKODI` (the kodkod backend
  runs the `kodkodi` binary), `NUNCHAKU_PARADOX`, `NUNCHAKU_SMBC` — naming
  the variable, whether it was
  set, and the path chosen.  The unavailable-solver line becomes
  `Utils.warningf Warn_solver_unavailable`, printing
  `[Warning solver not available: cvc5, paradox]`, with a `-W3 <bool>`
  toggle beside `-W1`/`-W2`.  It is in the default-enabled list because the
  line it replaces prints unconditionally today and is the only signal that
  an explicitly requested solver was dropped while the others ran (§3's
  non-zero exit covers only the case where *none* is available);
  defaulting the new warning off would delete a live diagnostic.
  On a stock Isabelle installation it therefore prints on every run, naming
  paradox, which Isabelle requests and no Isabelle distribution ships (§3);
  the sample line above is from a configuration that was also missing cvc5.
- **Repro**: `nunchaku --debug 3 --solvers cvc5 x.nun` now answers "which
  binary did this run use" with one line naming `NUNCHAKU_CVC5`, whether it
  was set, and the path chosen; before, the `NUNCHAKU_*` override and the
  PATH fallback both ended in a bare `exec` and the question could not be
  answered from outside.  The unavailable-solver line reads
  `[Warning solver not available: cvc5, paradox]` where it used to be an
  unframed stderr line with no toggle.

## 12. An empty `NUNCHAKU_*` variable is an error (commit: TBD)

- **Motivation**: `NUNCHAKU_CVC5=""` was read as "not set" and fell
  back to whatever `cvc5` the PATH offers — the silent-degradation
  shape these variables exist to remove.
- **Behavior**: an empty value fails, naming the variable and both ways
  out.  The change is in `Utils.external_program` (documented in
  `Utils.mli`), the funnel of §11, so it holds for all five `NUNCHAKU_*`
  variables and not for `NUNCHAKU_CVC5` alone.  A real
  path and an unset variable are unchanged.  Reporting the backend
  unavailable instead was considered and rejected: under
  `--solvers cvc5,smbc` the output still begins with `SAT`, the branch
  Isabelle classifies on, so it would never see a stderr warning and a
  certified two-solver configuration would quietly become one solver.
  Exit 1 does not contradict §13's rule that a solver reply is never fatal:
  this is a configuration error, settled before any solver is run, not
  something a solver sent.
- **Repro**: `NUNCHAKU_CVC5= nunchaku --solvers cvc5 x.nun`; before: a
  SAT model from some cvc5 on the PATH; after:
  `failure: NUNCHAKU_CVC5 is set to the empty string: set it to a path,
  or unset it to look cvc5 up in the PATH`, exit 1.
  `NUNCHAKU_CVC5= nunchaku --solvers smbc x.nun` still answers, exit 0:
  the variable of a solver you did not request is never read, because
  membership of the requested list is tested before availability is checked
  at all.
- **The wrapper's discipline is load-bearing**: Isabelle requests all
  four of `cvc5 kodkod paradox smbc`, so an empty value for *any* of
  them fails every Isabelle call.  That is the intended loudness, but
  it means `component/x86_64-linux/nunchaku` must never export an empty
  value — today it exports one unconditional absolute path.

## 13. A solver reply is never fatal, for the whole decoder (commit: TBD)

- **Motivation**: §8 stated the rule — nunchaku's own broken
  invariants are `Error`, anything the solver sends that we cannot
  understand is `Backend_err` — but made it true only of the
  finite-domain reply.  The get-value reply is decoded by a different
  function, and `get_model_`'s two decoder errors plus every parse error
  in `parse_simple_model_` / `parse_term_` / `parse_ty_` still raised
  `Error`, which is reported as `Res.Error`, which the backends pair with
  `S.Shortcut` (`S` is the `Scheduling` module): exit 1 with the
  sibling backends killed.  A rule that is written down and not true is
  worse than no rule, and §9's tightened character class made it
  worse still.
- **Repro** (canned replies, malformed in the get-value answer rather
  than the domain answer), before → after, all `--solvers cvc5 -j 1`:

  | reply | before | after |
  | --- | --- | --- |
  | unterminated string literal | `Error: … lexer error`, rc=1 | `UNKNOWN (BACKEND_ERROR …)`, rc=0 |
  | `sat` then EOF | `Error: … unexpected end of input`, rc=1 | same message under `UNKNOWN (BACKEND_ERROR …)`, rc=0 |
  | `(this is not a model)` | `Error: … expected pair key/value`, rc=1 | same message under `UNKNOWN (BACKEND_ERROR …)`, rc=0 |
  | ESC inside a get-value string | `Error: … illegal character 0x1b`, rc=1 | same message under `UNKNOWN (BACKEND_ERROR …)`, rc=0 |

  The last row is a fatal that fork `main` does not have: `main` prints
  `SAT` with the escape byte in the model.
- **Behavior**: everything from `find_atom_` down decodes what the solver
  sent, which is untrusted input; that whole region raises `Backend_err`,
  and a comment at its head says so, so the next decoder function added is
  right by default.  `Error` keeps exactly the invariants that cannot
  depend on a reply — witness lookup and problem printing.
  `parse_simple_model_` no longer looks its key up with `ID.Tbl.find` and
  `assert false`: it names the four ways a key can be wrong, so a reply
  about a symbol we never asked about is reported instead of escaping as
  a bare `Not_found`.
- **`read_res_` also catches anything else the decoder throws**, reports
  it as a backend error and warns with the exception named.  This is not
  belt-and-braces: with a stale cvc5, three of the 200 in-tree problems
  ended in an uncaught OCaml exception, because §8 stopped the run
  shortcutting on a fabricated model and the later option arms -- cvc5 is
  retried under several option sets, `Cvc5.options_l` -- then reached
  decoder bugs `main` never got to — `bench/bugs/pseudo_prop.nun`
  (`FO.Util.Parse_err`), `bench/tests/sat/data_select.nun`
  (`FO.Env.UndefinedID`) and `bench/tests/unsat/nat_le.nun`
  (`Model.ml:269 Assertion failed`).  Until this patch those three
  falsified the claim of `UNKNOWN` and exit 0 that README.adoc and §8
  both make.  `Sys.Break` and `Out_of_memory` are re-raised: they are
  conditions of the process, not properties of the reply.
- **`Model.ml`'s assertion is named, not masked**: it is reachable from a
  backend's reply, so it becomes an `invalid_arg` spelled like the sibling
  case above it — `DT.of_flat: case tests an unbound variable` — and a
  backend can report a cause instead of a file and a line number.

## 14. Negative controls for the spurious-model policy (commit: TBD)

- **Motivation**: one arm of §7's policy has no natural witness anywhere in
  the benchmark, so nothing would notice if it stopped working.  `Kodkod.ml`
  never reads the problem metadata, so an `unsat` from kodkod
  used to be reported as a refutation even when the encoding had lost
  models; the stage in `close_task` closes that hole without touching
  `Kodkod.ml`, and no other test in the tree exercises it.  Separately, the
  proposal to narrow the marking was rejected on a witness, and a rejected
  proposal with no test outlives the argument that killed it.
- **Fix**: three hermetic guard cases in a new `regress/soundness_guard/` --
  the missing arm, the rejected
  proposal, and a positive control -- each replaying a canned solver reply
  through the fake solver described under "Hermetic guard suites" below, in
  the shape the cvc5 guard suite established.  Hermetic here means
  no real solver and no dependence on anything outside the tree: the reply is
  a file in the repository.  The directory holds one `dune`, the three
  problems (`fun_quant.nun`, `c5evade.nun`, `c5control.nun`), the three
  canned replies (`reply_kodkod_unsat.txt`, `reply_c5evade.txt`,
  `reply_c5control.txt`) and the three expected outputs
  (`kodkod_unsat.expected`, `c5evade.expected`, `c5control.expected`).
  - `kodkod_unsat` is the kodkod arm.  Its problem `fun_quant.nun` is built
    for the case: every type in it is finite, so kodkod's universe has a
    deduced maximum cardinality and the bound-increment loop accepts the
    first `unsat` rather than retrying with a bigger bound — a retry would
    report `INCOMPLETE` by itself and prove nothing.  Canned reply
    `---OUTCOME--- UNSATISFIABLE`; expected `UNKNOWN (INCOMPLETE …)`,
    exit 0, where the fork's `main` as it stood immediately before §7 landed
    answers `UNSAT`.  That state of `main` is `a33dd0d`; it is a few commits
    after §6's `5a8a037` because the commits between the two are regression
    baseline data and a documentation edit, not patches, so no entry of this
    file claims them.
  - `c5evade` is the sealed record of a rejected proposal: narrowing the
    marking to problems that mention `abstract` would unmark this one, and
    it would then print a model of a statement that has none.  Canned smbc
    SAT reply; expected `UNKNOWN (POTENTIALLY_SPURIOUS …)`, where
    `a33dd0d` prints the model.  Any change that turns this into `SAT` is
    a soundness regression.
  - `c5control` is its positive control — the same statement without the
    copy type, which is genuinely refutable.  Canned smbc UNSAT reply;
    expected `UNSAT`, unchanged from `a33dd0d`, so the guard cannot pass
    by suppressing everything.
- **Ordering, in the commit's own words**: this entry REQUIRES
  `regress/support/` (the fake solver and the golden-file driver), which
  arrives with the cvc5-guard batch (§8–§13): on its own this commit's rules
  have no `run_case.exe` to depend on and `dune runtest` cannot resolve them.
  Apply it after that batch.
- The canned replies were captured from the real solvers (kodkodi 1.5.7,
  smbc 0.6.1) and name only symbols of the source problem, so they do not
  churn when ids shift downstream.

## 15. Typed-unknown environment for smbc models; every node converted once (commit: TBD)

- **Motivation**: §4's follow-up recovered types by converting a term,
  reading the type off the result, and converting it a second time with an
  expectation.  Four sites did this -- the general `A.HO_app` branch, the
  `A.Match` scrutinee, `A.Eq` and `A.Distinct` -- so nesting them
  multiplied.  Decoding a SAT answer could run for a minute with nothing to
  show for it, and all of it happens *after* smbc has answered, outside
  every deadline: nested `=` at depth 24 took 32.6 s, nested `distinct` at
  depth 28 took 56.7 s, and a linear chain of 250 applications never
  finished within 60 s.  Nested `distinct` needs no unknown at all and
  produced byte-identical output, i.e. it was pure cost.  Separately, one
  unknown could be recovered at two different types with nobody noticing,
  and what got recovered depended on the order in which smbc happened to
  emit its entries.
- **Fix**: delete all four re-conversions.  The model parse now carries a
  **typed-unknown environment** -- a union-find over the ids of smbc's
  unknowns, one type and one poison flag per class -- and each of the four
  sites *registers* what it knows instead of converting again: `A.Eq` and
  `A.Distinct` that their operands share a type, `A.HO_app` and `A.Match`
  that an operand has a particular one.  One linear pass per value term
  applies the result once the whole model has been read.  Registration keys
  on the unknown's identity, recognising both the untyped and the
  already-typed hole, so a constraint cannot be lost to whatever conversion
  learned first.  A class with two incompatible types is poisoned: one
  warning naming the unknown as smbc named it, and *every* occurrence of
  that class printed as `?__unparsable <ty>`, where `<ty>` is the type that
  occurrence itself knows, or failing that the type the class was poisoned
  with (a poisoned root always carries one) -- never one identity standing
  for two types, and never an opaque `?__ ?w1` token left behind, which is
  not an identifier and would cost the reader the whole model block.
  There is no fixpoint; the union-find is confluent by construction.
- **The opaque hole is still reachable, and that is the honest boundary.**
  An unknown whose type is determined nowhere in the model -- the shape is an
  applied hole whose argument is itself untyped, `(?f ?g)` -- still prints as
  `?__ ?name`, exactly as it does on pristine nunchaku, and the whole model
  block is still lost to a consumer that cannot parse that token.  No
  mechanism anyone built recovers it, and §4's "with no type at hand the old
  opaque hole is kept" is still the rule.  What changed is the *reach* of the
  recovery: coverage is no longer "did someone enumerate this syntactic
  position?" but "is this unknown's type determined anywhere in the model?",
  which is a property of the model.  `?__unparsable <ty>` is used only where
  a type *is* known and is contradictory (above) or where the entry could not
  be converted at all (§16) -- never as a rescue for a genuinely untyped
  unknown.
- **State is per parse.**  The record is created in `convert_model` and
  threaded.  The module-level `ID.Erase` table it sits next to is never
  reset, so anything kept there leaks from one problem to the next in the
  same process; the unknown-name table moved out of it for the same reason.
- **Invariant, stated in the source above `term_of_tip`**: every `A.term`
  node is converted exactly once.  Checkable by eye: no two `term_of_tip`
  calls take the same argument.
- **Repro**: a canned smbc answer nesting `=` 24 deep
  (`regress/smbc_models/gen_deep.py eqn 24`); before: 32.6 s, after:
  0.02 s.  `dist 28`: 56.7 s -> 0.05 s.  Linear application chains of
  250 / 500 / 1000 / 2000 / 4000: over 60 s at every one of those lengths,
  now 0.02 / 0.03 / 0.04 / 0.10 / 0.27 s respectively -- linear in model
  size.  Order independence: `regress/smbc_models/models/m_cross.txt` and
  `m_cross2.txt` are the same model with its two entries swapped and now
  give the same answer.  130 problems from `bench/`, `data/` and
  `regress/gold.nun` with real smbc 0.6.1: no output change.
- **Recorded, not fixed**: the parser asks "does this converted term have a
  type?" through `E.to_opt (T.ty ~env _)`, and `T.ty` is
  `try … with e -> err_of_exn e`, so it collapses *every* exception into the
  same `None` -- an unknown id, an ill-typed application and an internal
  failure are indistinguishable there.  Two of the sites that asked it that
  way disappeared with the re-conversions; the survivors only *learn*, so
  a collapsed exception costs a recovery and never a verdict.  Noted in the
  source next to `set_term_type`.

## 16. The smbc model parser treats its input as untrusted (commit: TBD)

- **Motivation**: the model comes from a separate program, and the parser
  asserted on it in several places and aborted the whole run on it in two
  more.  A malformed match arity, a lambda whose declared domain disagrees
  with the expected type, or one unreadable value ended the process.  Worse,
  any failure to *read* smbc's output was reported as a fatal error with a
  scheduling shortcut, which stops the sibling backends -- so a cvc5 answer
  to the same problem survived smbc *crashing* and was lost when smbc's
  output merely failed to parse.  smbc 0.6.1 emits `Match_default`, which
  makes the "match names no known constructor" shape reachable for the
  first time in the shipping configuration.
- **Fix**, one sentence now written in the source: *the model parser treats
  smbc output as untrusted input; it reports, it never asserts.*
  Concretely: three assertions on solver-supplied data become errors -- the
  match arity (naming both arities), a TIP cast (`(as t ty)` in the TIP
  syntax smbc answers in, which smbc 0.6.1 does not emit -- but nothing in
  the parser depended on that), and the
  assumption that two `if` branches of one value bind the same type; a
  match no branch of which names a *known* constructor, over an untyped
  scrutinee, gets a message saying exactly that; an `A.Fun` whose domain
  disagrees with the expectation warns and drops the expectation;
  `convert_model` contains a failed value conversion per entry, warning and
  emitting `?__unparsable <ty>` for that symbol alone; and a failure to
  read smbc's output becomes `Res.Unknown [U_backend_error]` with
  `No_shortcut`, exactly like the non-zero-exit path next to it.  Only
  exceptions raised while converting smbc's *answer* are contained;
  `Out_of_scope` and `Conversion_error`, which despite the name concern the
  problem we *sent*, stay fatal.
- **User-visible cost, recorded**: a *single-backend* run on a model that
  cannot be read goes from `Error: …` / exit 1 to
  `UNKNOWN (BACKEND_ERROR …)` / exit 0.  The Isabelle frontend is
  unaffected: it classifies on the `SAT` prefix of the output.
- **Repro**: `regress/smbc_models/models/m_defonly3.txt` on
  `problems/headpos.nun`; before: `undefined ID: ?l1`, exit 1; after: a
  warning, `val xs_ := (?__unparsable list_)`, the rest of the model, exit
  0.  For the sibling: the same setup with a cvc5 that answers one second
  later; before, cvc5's model is lost, after it is delivered.
  Two shapes that used to end in `Assertion failed` with a file and a line
  number: a TIP cast, now a delivered model carrying
  `val c_ := (?__unparsable a_)`; and two `if` branches taking arguments of
  different types, now `UNKNOWN (BACKEND_ERROR … two branches of the same
  value take arguments of different types, `a_` and `b_`)` -- that one
  stays a contained backend error rather than a delivered model, because
  the lambda hoisting runs after the entries are converted.

## 17. Faithful `-o sexp` for typed unknowns; one product printer for models (commit: TBD)

- **Motivation**: two small losses of information on the output side.
  `Builtin.to_sexp` printed every `` `Undefined_atom `` as a bare `?__`, so
  distinct unknowns came out as identical tokens -- while the
  same file printed `` `Undefined_self `` and `` `Unparsable `` faithfully,
  making the *typed* hole the one lossy case.  And the potentially spurious
  `SAT:` branch printed the model with `Model.pp` while the ordinary branch
  used `Model.Default.pp_standard`, i.e. two product surfaces for one
  datum, selected by a flag that says nothing about formatting.  `Model.pp`
  shows decision trees as they are (`cases (x:ty) {{C -> a}; {D -> b}}`),
  which is a debugging view; `Model.mli` describes `pp_standard` as the
  "printer suitable for parsing from the caller".
- **Fix**: `Undefined_atom` prints `?__<n>` in sexp, mirroring the default
  printer; both `SAT:` branches use `pp_standard`.  The
  `(potentially spurious)` marker is untouched, and `Model.pp` stays
  reachable under `--debug`.
- **Consequence for golden files**: the two printers list entries in
  opposite orders, so unifying them reorders the entries of a potentially
  spurious model.  Neither order is meaningful.
- **Repro**: `-o sexp` on a model with six unknowns; before `?__` six
  times, after `?__46 ?__47 ?__50 ?__51 …`.

## 18. One failing backend no longer discards the other backends' answers (commit: TBD)

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
  The run fails only when every task raised and none produced a result --
  and that call is `process_res_`'s, not the pool's (§19).
  (§19 also settles the remaining case: neither results nor exceptions is a
  timeout, not a failure.)  A raise is never silently swallowed where it
  could matter: if the run ends in `UNKNOWN`, each exception is reported as
  a `BACKEND_ERROR` line of it.  If a sibling produced a conclusive verdict,
  that verdict is the answer -- the repro below ends in a bare `UNSAT`.
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
- **Repro**: `NUNCHAKU_PARADOX=<fake solver replaying a canned reply>
  nunchaku --solvers cvc5,smbc,paradox --timeout 5` on a refutable
  copy-free problem;
  before: `Error: Paradox: parsing model failed`, exit 1; after: `UNSAT`,
  exit 0, 3 runs out of 3.

## 19. `--timeout` is a wall-clock deadline, not a hint (commit: TBD)

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
  diagnostic back means letting a killed task report on its way out; that is
  deferred until someone misses it.
- **Who decides that a run failed**: not the pool.  It reports the results
  it collected and the exceptions it caught (§18), and `process_res_` reads
  that once: nothing but exceptions, one per task, is a broken installation
  and exits 1; an exception beside a timeout is a `BACKEND_ERROR` line under
  the `TIMEOUT` one, because a backend that died must not become invisible
  behind the clock.  The exceptions are reversed at that boundary, so they
  come out in the order they were raised and the first task to raise is the
  first one reported.
- **Also**: the `Scheduling` qtests passed `~deadline:5.`, an absolute
  time in 1970, which the tests survived because the pool's own wait never
  consulted it; they now pass `Unix.gettimeofday () +. 5.`
- **Repro**: captured Isabelle problem for `n1`, `--solvers cvc5`; before:
  7.05 s at `--timeout 5`, 5.57 s at `--timeout 1`; after: 5.01 s and
  1.01 s, same verdict.

## Recorded exposure: the wrapper pins only cvc5

`component/x86_64-linux/nunchaku` exports **only** `NUNCHAKU_CVC5`, and
Isabelle invokes it with `PATH="$CVC5_HOME:$KODKODI/bin:$SMBC_HOME:$PATH"`,
so smbc, kodkodi and paradox are resolved from Isabelle's PATH even in the
shipped configuration.  That is intended *while* those solvers come from the
Isabelle distribution, which is what `regress/README.md` §2 records for smbc.
The moment a self-built smbc is bundled into the component, the
wrapper must also export `NUNCHAKU_SMBC="$NUN_DIR/solvers/smbc"` — and
`NUNCHAKU_KODKODI` for any bundled kodkodi — or Isabelle's `$SMBC_HOME`
binary wins and the combination that runs is not the one that was
certified.  The code change belongs with the smbc bundling work; this is
the record that it is owed.

## Hermetic guard suites (`regress/cvc5_guard/`, `regress/soundness_guard/`, `regress/smbc_models/`, `regress/support/`)

`regress/` holds two unrelated harnesses: the Isabelle-driven benchmark and
its gate (`bench.ML`, `bench2.ML`, `gold.nun`, the checked-in baseline), and
the `dune runtest` guard suites described here.  The benchmark drives
Isabelle against the bundled cvc5 and structurally
cannot produce a stale-solver or malformed reply, and the gate has no
column for "must fail loudly".  The three guard suites replay canned replies
through a fake solver under `dune runtest`, so the loud-failure behaviour
of §8, §9, §12, §13 and §16 and the negative controls of §14 are pinned on
every platform leg and on a developer's machine before pushing.  All three
sit under `dune runtest` and all three are driven by
`regress/support/run_case`.

`regress/cvc5_guard/` holds the cvc5 reply cases.  Two of them are positive
controls on the full model text — one base sort, one compound witness sort
— so "rejects everything" fails as loudly as "accepts everything".

`regress/soundness_guard/` holds §14's three cases: the kodkod `unsat` arm of
the spurious-model policy, the sealed record of the rejected proposal to
narrow the marking, and that record's positive control.

`regress/smbc_models/` holds the smbc model-parser corpus: per case a
problem, a canned smbc answer, and for the deeply nested ones a generator
(`gen_deep.py`).  It covers unknowns that get a type (including the
order-independent pair `m_cross` / `m_cross2`, the same model with its two
entries swapped, which must give the same answer both ways); unknowns that
honestly cannot get one (`(?f ?g)`, an applied hole whose argument is
itself untyped); one identity used at two types (one warning, every
occurrence `?__unparsable`); entries that cannot be read at all (one entry
lost, the model delivered); and the deeply nested families of §15, each with a
wall-clock ceiling and its own rule, so a timing regression names itself
instead of appearing as a golden mismatch.  Two of the answers are captured
verbatim from real smbc 0.6.1 rather than written by hand.

The cvc5 rules are all the same shape, so they are generated: the case table
is in `gen_dune.ml`, `dune.inc` is promoted from it and kept honest by a
runtest diff, and `(include dune.inc)` works at `(lang dune 2.0)`.  Adding
a case is a line in the table plus its reply file.

`regress/support/` holds the two executables the suites share:

- `fake_solver.ml` — prints the file named by `FAKE_REPLIES`, closes
  stdout (which is what lets a reply end mid-token), then drains stdin.
- `run_case.ml` — runs nunchaku under a wall-clock deadline, captures
  stdout and stderr separately, normalises the output and prints one
  deterministic report ending in `rc=<n>`.  It exists because at
  `(lang dune 2.0)` a rule cannot declare a non-zero expected exit
  (`with-accepted-exit-codes` needs 2.2) and cannot pipe (`pipe-stdout`
  needs 2.7); the language level is deliberately not raised for a test
  convenience.  A wall-clock deadline cannot be spelled in the rule
  either — `timeout(1)` is coreutils and absent from stock macOS.

  It runs the child in its own process group and signals the group at the
  deadline: nunchaku spawns every backend through `/bin/sh -c`, so
  killing its pid alone leaves the solvers running, reparented to init.

The normalisation contract, which any new case is written against:

- `?__<n>` and every `name/<id>` variable spelling are renamed
  canonically **by first appearance** (`?__1 ?__2 …`, `v1 v2 …`), so two
  occurrences of the same unknown stay the same and two different ones
  stay different — the properties the goldens exist to guard — while the
  process-level counter is removed.
- `time:<t>s` becomes `time:Ns`, and the whole `message="options: …"`
  payload a fixed string, so a timing wobble does not churn every
  expected file.
- A run of identical adjacent entries in an `UNKNOWN (…)` list collapses
  to one, and so does a run of identical adjacent warning blocks on
  stderr: otherwise every golden would pin the number of option arms in
  `Cvc5.options_l`, which is the same churn by another route.
- Every case runs with `-j 1`.

## Generated numbers in model output: the `?__<n>` / `v_N/M` contract

`?__<n>` is the process-global `ID.id` counter of an unknown's id, and
`v_<n>/<m>` is a generated variable name plus the same counter.  They
identify a thing **within one printed model** -- two `?__46` are the same
unknown, `?__46` and `?__47` are different ones -- and carry no other
meaning.  The value depends on how many ids the pipeline allocated before
reaching the model, so it moves whenever unrelated code changes, and it is
not stable across builds, across versions, or between two runs whose
pipelines differ.  Consumers must not read anything into the number, and
golden comparison must normalise both forms *and* collapse whitespace: the
pretty printer wraps on the pre-normalisation column width, so `v_0/8299`
and `v_0/133` break lines differently from identical token streams.  See
`regress/smbc_models/README.md`.

This applies to the reproductions in this file too: a `?__117` or a
`?__46 ?__47` above is the number that run happened to print, not a number
yours will print.  Read them as "a number", and where one repeats within a
repro, as "the same number".
