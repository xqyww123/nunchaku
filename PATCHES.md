# Patches this fork carries

Policy: PR-first.  Every patch is submitted upstream
(`nunchaku-inria/nunchaku`); the fork only keeps carrying what upstream
declines or leaves unhandled, and a merged patch is dropped from this list
at the next sync.  Base commit: d23a876.

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
- **Upstream PR**: https://github.com/nunchaku-inria/nunchaku/pull/56 (open).

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
- **Upstream PR**: https://github.com/nunchaku-inria/nunchaku/pull/57 (open).

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
- **Upstream PR**: https://github.com/nunchaku-inria/nunchaku/pull/58 (open).

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
- **Upstream PR**: https://github.com/nunchaku-inria/nunchaku/pull/59 (open).


## 5. `--version` placeholder never expanded (`src/main/dune`)

- **Motivation**: the `Const.ml` generation rule echoes `${version:nunchaku}`
  literally — dune 2 variables are `%{...}` — so `--version` has printed the
  raw placeholder since the dune 2 migration.  Cosmetic for the Isabelle
  frontend (it never calls `--version`), but release hygiene: the CI smoke
  asserts the placeholder is gone.
- **Repro**: `nunchaku --version`; before:
  `nunchaku ${version:nunchaku} <sha>`; after: `nunchaku 0.6 <sha>`
  (dev checkout) / the tag version (released build, via `dune subst`).
- **Upstream PR**: https://github.com/nunchaku-inria/nunchaku/pull/60 (open).

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
- **Upstream PR**: https://github.com/nunchaku-inria/nunchaku/pull/61 (open).

## 7. Strict parsing of cvc5's finite-domain reply

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
  rejection — and every unparseable reply in either SMT backend, which
  is the same change at `Cvc5.ml`'s and `CVC4.ml`'s sexp decoder — is
  `Backend_err`, i.e. `UNKNOWN (BACKEND_ERROR …)` and exit 0 with the
  sibling backends untouched, never a fatal `Error`.  The rule is
  written next to the two exception definitions: `Error` is for
  nunchaku's own broken invariants, anything the solver sends that we
  cannot understand is `Backend_err`.
- **Repro**: `NUNCHAKU_CVC5=<cvc5 1.2.0> nunchaku --solvers cvc5 -j 1`
  on a problem needing three distinct elements of an uninterpreted
  type; before: `SAT: { type a_ := {$a__0, $a__1}. val z_ := @a___2. }`
  — a model with two elements for a goal that needs three, and a value
  outside the domain it just printed; after:
  `UNKNOWN (BACKEND_ERROR … cvc5 rejected `get-model-domain-elements` …)`,
  exit 0.
- **The TY comparison does not use `pp_gty`**: that printer mangles
  every non-alphanumeric character and flattens application to
  `_to__a__b__`, where cvc5 echoes the sort as it was declared,
  `(to_ a_ b_)` — a list, not an atom.  Measured over the 200 in-tree
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
  counter shifts.  One problem (`bench/bugs/ho_copy_set2.nun`) went from
  an uncaught `FO.Env.UndefinedID` to a model for the same reason.
- **CVC4 is not affected and must not be "completed" later**: its
  `get_finite_domain_` reads an explicitly declared cardinal
  (`(fmf.card.val …)`, parsed by `parse_int_`), not a list length.
  There is no counting defect there to port a fix to.  Only the sexp
  decoder change above touches `CVC4.ml`.
- **Upstream PR**: not yet submitted.

## 8. String literals scanned by a lexer sub-rule

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
- **Repro**: a reply carrying `(a "l1\nl2 tail<ESC>x")`; before:
  the ESC byte reaches stdout verbatim; after:
  `line 2, col 7 to 8: illegal character 0x1b in string literal`.  A
  reply cut off mid-literal: before, `Error: in the interface to cvc5:
  … lexing failed on char "` and the run aborts; after,
  `line 1, col 7 to line 2, col 7: unterminated string literal` and
  exit 0 (patch 7 is what makes the tightening safe: a strict lexer
  whose every complaint is fatal would be a reliability regression).
- **Upstream PR**: not yet submitted.

## 9. Unquoting a backend's error message for display

- **Motivation**: a string literal reaches the model layer as its raw
  lexeme — delimiters kept and inner quotes still doubled — so cvc5
  answering `(error "has ""doubled"" quotes")` printed
  `BACKEND_ERROR {…} "has ""doubled"" quotes"`.
- **Behavior**: `Sexp_lib.unquote_atom` undoes the convention, in the
  module that created it, and is called at the two places that display
  a payload (`Cvc5.ml`, `CVC4.ml`) and nowhere else.  Atoms stay
  wire-faithful everywhere else, and patch 7's guard keeps echoing raw
  replies by construction, because it formats a `Sexp_lib.t` and never
  an atom payload.
- **The alternative is dead, not merely unchosen**: unescaping inside
  the lexer would destroy both that echo and the ability to tell an
  atom from a string — which is exactly what patch 7's
  `` `List (`Atom "error" :: _) `` match depends on.  Nobody should
  revive it.
- **Upstream PR**: not yet submitted.

## 10. Which binary a backend chose, and the unavailable-solver warning

- **Motivation**: with `NUNCHAKU_*` overriding a PATH lookup there was
  no way to ask from the outside which binary a run actually used; and
  the aggregated unavailable-solver line was a bare `Format.eprintf`
  with no toggle and none of the framing every other warning gets.
- **Behavior**: one `Utils.debugf` in `Utils.external_program`, the
  funnel all five backends share, naming the variable, whether it was
  set, and the path chosen.  The unavailable-solver line becomes
  `Utils.warningf Warn_solver_unavailable`, printing
  `[Warning solver not available: cvc5, paradox]`, with a `-W3 <bool>`
  toggle beside `-W1`/`-W2`.  It is in the default-enabled list: it
  prints today unconditionally and is the only signal that an
  explicitly requested solver was dropped.
- **Upstream PR**: not yet submitted.

## 11. An empty `NUNCHAKU_*` variable is an error

- **Motivation**: `NUNCHAKU_CVC5=""` was read as "not set" and fell
  back to whatever `cvc5` the PATH offers — the silent-degradation
  shape these variables exist to remove.
- **Behavior**: an empty value fails, naming the variable and both ways
  out (`Utils.external_program`, documented in `Utils.mli`).  A real
  path and an unset variable are unchanged.  Reporting the backend
  unavailable instead was considered and rejected: under
  `--solvers cvc5,smbc` the output still begins with `SAT`, the branch
  Isabelle classifies on, so it would never see a stderr warning and a
  certified two-solver configuration would quietly become one solver.
- **Repro**: `NUNCHAKU_CVC5= nunchaku --solvers cvc5 x.nun`; before: a
  SAT model from some cvc5 on the PATH; after:
  `failure: NUNCHAKU_CVC5 is set to the empty string: set it to a path,
  or unset it to look cvc5 up in the PATH`, exit 1.
  `NUNCHAKU_CVC5= nunchaku --solvers smbc x.nun` still answers, exit 0.
- **The wrapper's discipline is load-bearing**: Isabelle requests all
  four of `cvc5 kodkod paradox smbc`, so an empty value for *any* of
  them fails every Isabelle call.  That is the intended loudness, but
  it means `component/x86_64-linux/nunchaku` must never export an empty
  value — today it exports one unconditional absolute path.
- **Upstream PR**: not yet submitted.

## Recorded exposure: the wrapper pins only cvc5

`component/x86_64-linux/nunchaku` exports **only** `NUNCHAKU_CVC5`, and
Isabelle invokes it with `PATH="$CVC5_HOME:$KODKODI/bin:$SMBC_HOME:$PATH"`,
so smbc, kodkodi and paradox are resolved from Isabelle's PATH even in the
shipped configuration (`regress/README.md` §2 states this as intended for
smbc).  The moment a self-built smbc is bundled into the component, the
wrapper must also export `NUNCHAKU_SMBC="$NUN_DIR/solvers/smbc"` — and
`NUNCHAKU_KODKODI` for any bundled kodkodi — or Isabelle's `$SMBC_HOME`
binary wins and the combination that runs is not the one that was
certified.  The code change belongs with the smbc bundling work; this is
the record that it is owed.

## Hermetic guard suites (`regress/cvc5_guard/`, `regress/support/`)

`regress/` drives Isabelle against the bundled cvc5 and structurally
cannot produce a stale-solver or malformed reply, and the gate has no
column for "must fail loudly".  `regress/cvc5_guard/` replays canned
replies through a fake solver under `dune runtest`, so the loud-failure
behaviour of patches 7, 8 and 11 is pinned on every platform leg and on a
developer's machine before pushing.

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

The normalisation contract, which any new case is written against:
`?__<n>` and `v_<n>/<m>` are renamed canonically **by first appearance**
(`?__1 ?__2 …`, `v1 v2 …`), so two occurrences of the same unknown stay
the same and two different ones stay different — the properties the
goldens exist to guard — while the process-level counter is removed.
`time:<t>s` becomes `time:Ns` and the whole `message="options: …"`
payload becomes a fixed string, so a timing wobble or an edit to
`Cvc5.options_l` does not churn every expected file.  Every case runs
with `-j 1`.
