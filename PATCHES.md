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
