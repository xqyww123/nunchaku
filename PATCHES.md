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
- **Second follow-up**: the shape this follow-up introduced -- convert a
  node, read the type off the result, convert it again with an expectation
  -- was replaced wholesale in patch 7 below.  Do not restore it.
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

## 7. Typed-unknown environment for smbc models; every node converted once

- **Motivation**: patch 4's follow-up recovered types by converting a term,
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
  typed-unknown environment -- a union-find over the ids of smbc's
  unknowns, one type and one poison flag per class -- and each of the four
  sites *registers* what it knows instead of converting again: `A.Eq` and
  `A.Distinct` that their operands share a type, `A.HO_app` and `A.Match`
  that an operand has a particular one.  One linear pass per value term
  applies the result once the whole model has been read.  Registration keys
  on the unknown's identity, recognising both the untyped and the
  already-typed hole, so a constraint cannot be lost to whatever conversion
  learned first.  A class with two incompatible types is poisoned: one
  warning naming the unknown as smbc named it, and every occurrence printed
  as `?__unparsable <ty>` -- never one identity standing for two types.
  There is no fixpoint; the union-find is confluent by construction.
- **State is per parse.**  The record is created in `convert_model` and
  threaded.  The module-level `ID.Erase` table it sits next to is never
  reset, so anything kept there leaks from one problem to the next in the
  same process; the unknown-name table moved out of it for the same reason.
- **Invariant, stated in the source above `term_of_tip`**: every `A.term`
  node is converted exactly once.  Checkable by eye: no two `term_of_tip`
  calls take the same argument.
- **Repro**: a canned smbc answer nesting `=` 24 deep
  (`regress/smbc_models/gen_deep.py eqn 24`); before: 32.6 s, after:
  0.02 s.  `dist 28`: 56.7 s -> 0.05 s.  `chain 250 … 4000`: over 60 s at
  every depth, now 0.02 / 0.03 / 0.04 / 0.10 / 0.27 s -- linear in model
  size.  Order independence: `regress/smbc_models/models/m_cross.txt` and
  `m_cross2.txt` are the same model with its two entries swapped and now
  give the same answer.  130 problems from `bench/`, `data/` and
  `regress/gold.nun` with real smbc 0.6.1: no output change.
- **Recorded, not fixed**: the parser asks "does this converted term have a
  type?" through `E.to_opt (T.ty ~env _)`, and `T.ty` is
  `try … with e -> err_of_exn e`, so it collapses *every* exception into the
  same `None` -- an unknown id, an ill-typed application and an internal
  failure are indistinguishable there.  Two of the four sites with that
  shape disappeared with the re-conversions; the survivors only *learn*, so
  a collapsed exception costs a recovery and never a verdict.  Noted in the
  source next to `set_term_type`.

## 8. The smbc model parser treats its input as untrusted

- **Motivation**: the model comes from a separate program, and the parser
  asserted on it in four places and aborted the whole run on it in two
  more.  A malformed match arity, a lambda whose declared domain disagrees
  with the expected type, or one unreadable value ended the process.  Worse,
  any failure to *read* smbc's output was reported as a fatal error with a
  scheduling shortcut, which stops the sibling backends -- so a cvc5 answer
  to the same problem survived smbc *crashing* and was lost when smbc's
  output merely failed to parse.  smbc 0.6.1 emits `Match_default`, which
  makes the "match names no resolvable constructor" shape reachable for the
  first time in the shipping configuration.
- **Fix**, one sentence now written in the source: *the model parser treats
  smbc output as untrusted input; it reports, it never asserts.*
  Concretely: three assertions on solver-supplied data become errors -- the
  match arity (naming both arities), a TIP cast, and the assumption that two
  `if` branches of one value bind the same type; a match that names no resolvable constructor and has an untyped
  scrutinee gets a message saying exactly that; an `A.Fun` whose domain
  disagrees with the expectation warns and drops the expectation;
  `convert_model` contains a failed value conversion per entry, warning and
  emitting `?__unparsable <ty>` for that symbol alone; and a failure to
  read smbc's output becomes `Res.Unknown [U_backend_error]` with
  `No_shortcut`, exactly like the non-zero-exit path next to it.  Only the
  model-conversion exception family is contained -- `Out_of_scope` and
  `Conversion_error` concern the problem we *sent* and stay fatal.
- **User-visible cost, recorded**: a *single-backend* run on a model that
  cannot be read goes from `Error: …` / exit 1 to
  `UNKNOWN (BACKEND_ERROR …)` / exit 0.  The Isabelle frontend is
  unaffected: it classifies on the `SAT` prefix of the output.
- **Repro**: `regress/smbc_models/models/m_defonly3.txt` on
  `problems/headpos.nun`; before: `undefined ID: ?l1`, exit 1; after: a
  warning, `val xs_ := (?__unparsable list_)`, the rest of the model, exit
  0.  For the sibling: the same setup with a cvc5 that answers one second
  later; before, cvc5's model is lost, after it is delivered.

## 9. Faithful `-o sexp` for typed unknowns; one product printer for models

- **Motivation**: two small losses of information on the output side.
  `Builtin.to_sexp` printed every `` `Undefined_atom `` as a bare `?__`, so
  five distinct unknowns came out as five identical tokens -- while the
  same file printed `` `Undefined_self `` and `` `Unparsable `` faithfully,
  making the *typed* hole the one lossy case.  And the potentially-spurious
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
  opposite orders, so unifying them reorders the entries of a
  potentially-spurious model.  Neither order is meaningful.
- **Repro**: `-o sexp` on a model with six unknowns; before `?__` six
  times, after `?__46 ?__47 ?__50 ?__51 …`.

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
