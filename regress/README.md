# Re-certification manual

This directory certifies a nunchaku build against Isabelle2025-2's
`nunchaku` command.  It is self-contained: a fresh session should get from
a source checkout to a pass/fail verdict in about 30 minutes by following
this file top to bottom.  Every upstream sync is a re-certification event:
merge → build → gold test → gate → only then release.

Shipping configuration (what all of this certifies): `solvers = "cvc5 smbc"`,
`timeout = 1` plus a caller-side wall-clock cap.

## 0. What is here

| file | role |
| --- | --- |
| `bench.ML`, `bench2.ML` | benchmark drivers (78 goals total: Main-library classes + custom-datatype/large-witness classes), driven by env vars `BENCH_ENGINE` (nitpick \| nunchaku \| nunchaku_smbc \| nunchaku_ship) and `BENCH_TIER` (seconds) |
| `truthcheck.ML` | side-check that the goals labelled true are actually provable (run.sh runs it; UNPROVED lines are reported, not gated) |
| `DTBench.thy`, `DTBenchCheck.thy` | the custom datatypes for `bench2.ML`, and their sanity check |
| `NunGold.thy` | gold smoke test; loads in seconds, asserts programmatically, prints `GOLD_OK` |
| `aggregate.py` | fold `RESULT` lines from the logs into a TSV + summary (called once per part: `out_`/`out2_` prefixes) |
| `run.sh <workdir>` | run everything against the component under test |
| `gate.sh <workdir>` | pass/fail verdict of the fresh TSVs against `baseline/` |
| `baseline/` | checked-in reference TSVs and summaries |
| `bash_server_main.scala` | helper needed by both engines (below) |
| `tools/` | diagnostics that need no certification run: capture the problems Isabelle emits, and dump the metadata that drives the spurious-model marking (§6) |
| `cvc5_guard/` | hermetic guard suite for the cvc5 backend, run by `dune runtest`: canned replies pinning that a malformed or stale-solver answer is reported as a backend error and never fabricates a model or aborts the run |
| `soundness_guard/` | hermetic negative controls for the spurious-model policy, run by `dune runtest` (they use the shared `support/` driver) |
| `smbc_models/` | hermetic golden-file suite for the smbc model parser, run by `dune runtest` (same shared `support/` driver): 24 canned smbc answers, one `.expected` report each, and a wall-clock ceiling on the deeply nested ones so a decoding regression names itself as a timing failure.  The case table is `smbc_models/cases.tsv`; every case is explained in `smbc_models/README.md` |

Data format: each benchmark line is
`RESULT\tclass\tid\ttruth\tengine\ttier\tverdict\tms\tmodel`, ending with
`BENCH_DONE`.  The `truth` column is the truth label (`F` = a countermodel
is expected, `T` = the goal is a true proposition); `gate.sh` reads its
drift rules and the spurious-verdict rule from this column and needs no
other source of truth.  The `model` column records, for the nunchaku
engines, whether a refuting verdict came with a displayable model
(`yes`/`no`; `na` otherwise) -- the smbc model-hole class of defects
preserves the verdict and loses only the model, so without this column
the gate cannot see them.  The `nunchaku_ship` arm is the shipping
configuration (`solvers = "cvc5 smbc"`); the other nunchaku arms keep
kodkod for cross-checking.

## 1. Build nunchaku (~3 min)

```bash
export OPAMROOT=<an isolated dir OUTSIDE this repository>
opam init --bare --no-setup --disable-sandboxing
opam switch create trial ocaml-system        # system OCaml 4.14+ suffices
opam install -y --switch=trial --deps-only ./nunchaku.opam
opam exec --switch=trial -- dune build @install
# artifact: _build/default/src/main/nunchaku.exe
```

Release binaries are instead built statically (musl) by CI; for local
certification the artifact above is fine.

## 2. Assemble the component under test

Drop into a copy of `../component/` (or point `$NUNCHAKU_COMPONENT` at an
assembled one).  `../component/` holds the platform-independent skeleton, so
assembling a linux component means creating the `x86_64-linux/` directory and
filling it (`../component/README.md` describes the layout in full):

- `x86_64-linux/nunchaku` — the wrapper, copied from `../component/nunchaku`;
- `x86_64-linux/nunchaku-bin` — the freshly built `nunchaku.exe`;
- `x86_64-linux/solvers/cvc5` — a static cvc5 **≥ 1.3.1** (the backend
  sends `get-model-domain-elements`, which older cvc5 answers with an
  error);
- `x86_64-linux/solvers/smbc` — smbc **0.6.1**, built from
  `github.com/c-cube/smbc` at the commit `../component/solvers.pins` pins
  (`smbc-commit`; it is what tag `v0.6.1` resolved to on 2026-08-25).  The
  commit, not the tag: a git tag is mutable, and smbc stamps its `--version`
  from `smbc.opam`, so a re-cut tag would ship different bytes still reporting
  `0.6.1`.  Re-certifying a new smbc means editing that one line.  0.4.1, which the Isabelle
  distribution ships, cannot be rebuilt on any current toolchain: its
  dependencies cap OCaml below 4.08, and that era has no arm64 macOS
  backend at all.  0.6.1 needs `containers 2.8.1` from the opam archive
  repository (it uses the `containers.sexp` sublibrary that 3.x removed);
- substitute both placeholders in `etc/settings`: `@NUNCHAKU_VERSION@` with
  the content of the repository's `VERSION` file, and `@NUNCHAKU_PLATFORM@`
  with `x86_64-linux`.  `regress/lib_bootstrap.sh` refuses to run unless the
  resulting `NUNCHAKU_HOME` and `NUNCHAKU_VERSION` are the ones under test,
  so a forgotten substitution stops the gate rather than silently certifying
  the distribution's 2017 binary.

Both solvers are pinned by the wrapper, which is what makes the certified
combination the one that runs: Isabelle puts `$SMBC_HOME` on the PATH, so
without `NUNCHAKU_SMBC` the distribution's 0.4.1 would win.  kodkodi and
paradox are not bundled and stay whatever Isabelle's PATH offers; a wrapper
that ever bundles them must export their variables too.  Never export an
empty value: an empty `NUNCHAKU_*` is an error, and Isabelle requests all
four of `cvc5 kodkod paradox smbc`, so one empty value fails every call.

## 3. Gold test (seconds; before anything else)

```bash
./regress/run.sh <workdir> gold
```

`NunGold.thy` raises on failure and prints `GOLD_OK` on success.  It
asserts: verdict `genuine` on the false goal with the model displayed
(once under the shipping configuration, once under `solvers = "smbc"`
alone — the arm the smbc model-hole fixes live on, which the shipping
race would otherwise only exercise most of the time), wall clock within
cap, and a true goal not refuted.  (Alternative: load
`NunGold.thy` in any PIDE session whose `NUNCHAKU_HOME` points at the
component under test.)  Import gotcha for all probe theories: write
`imports "HOL.Nunchaku"` — a bare `imports Nunchaku` does not resolve.

About the bash server: a bare `isabelle ML_process` has no `bash_process`
environment, so neither engine could call its external tool.  `run.sh`
starts the server itself (`bash_server_main.scala`) and stops it on exit.
If you ever run one by hand, it must live in the same `HOME` (the
`<workdir>/fakehome`) as the runs: `bash_process` expands
`"$NUNCHAKU_HOME"` on the *server* side, so a server started from the
real home silently substitutes the distribution's bundled 2017 binary
for the component under test.  Also: do not pipe a script into
`isabelle scala` — the REPL refuses to start without a terminal; pass
the file as an argument as `run.sh` does.

## 4. Full run and gate

```bash
./regress/run.sh  <workdir>   # gold first, then ~30 min of arms
./regress/gate.sh <workdir>   # exit 0 = certified
```

`run.sh` refuses to start unless `<workdir>/fakehome` carries a copy of
the real `~/.isabelle/<version>/etc/preferences` (it copies it on first
use; a scratch user dir with default preferences can silently flip
`ML_system_64` and trigger an implicit 32-bit build) and verifies that
`NUNCHAKU_HOME` resolves to the component under test and that
`NUNCHAKU_VERSION` equals the repository's `VERSION` (catching an
unsubstituted `@NUNCHAKU_VERSION@`).  It never runs `isabelle build`.

Gate rules (also in `gate.sh`'s header): spurious verdicts on
true-labelled goals hard-fail at any tier; the 5 s tier must match the
baseline cell-for-cell, where `none` and `unknown` count as ONE verdict
(neither claims anything about the goal, and the distinction is exactly
what near-budget scheduling perturbs), with `none/unknown → genuine`
allowed only on false-labelled goals; a cell must not regress from
model-shown to model-missing; the 1 s tier is reported, not gated;
timings are advisory (3× median ratchet).  A quiet machine is still
recommended -- the timing ratchet reads better -- but load can no longer
flip the gate.

If the run improved on the baseline (allowed drifts only), refresh
`baseline/` from the new TSVs in the same commit that explains why.

The current `baseline/` was recorded for 0.5.3, against cvc5 1.3.4 and the
bundled smbc 0.6.1.  Three classes of cell moved against the 0.5.2 baseline,
and each is a consequence of a change this release makes on purpose:

- `n4` (four cells) and `b3` (two) lost their refutations.  Those goals carry
  `sat_means_unknown`, so their models may be spurious; the baseline records
  that none of them could be displayed anyway (`model=no`).  The fork no
  longer claims them.
- 28 cells went from `model=no` to `model=yes`: countermodels that used to
  reach Isabelle with a token its parser rejects — costing the whole model
  block — are now shown.
- `ls2/nunchaku_ship/1s` and `d2/nunchaku_smbc/1s` lost a countermodel they
  used to produce.  **This baseline records them wrongly**, and the reason is
  worth keeping: it was first read as the honest cost of §19 (the budget is a
  real deadline now, so a 1 s call gets one second).  It was not.  Both cells
  spent 1022-1023 ms and answered nothing, while the *same goals* answered in
  35-43 ms in a neighbouring arm of the same run — the signature of the
  descriptor race fixed in `PATCHES.md` §22, not of a goal that needs more
  time.  With that fix the three affected goals (`ls2`, `d2`, `d4`) answer in
  0 of 50 runs lost instead of 13-20 of 50.  **The baseline must be
  re-certified against a binary carrying §22**; until it is, these cells and
  the `ms` column of any cell near 1022 ms are suspect.

## 5. Release

Follow `RELEASE_CHECKLIST.md` in the packaging repository
(`isabelle-packaging-ci`); versions come from the `VERSION` file at the
repository root and are never written by hand.

## 6. Tools: which goals does the marking touch?

`tools/` answers, in about a minute and without a single solver call,
the question that otherwise costs a full arm sweep: *for which goals may
nunchaku's answer be untrustworthy, and in which direction?*

```bash
./regress/tools/capture.sh   <workdir>                       # a few minutes
./regress/tools/dump_meta.sh <workdir>/capture-component/problems/*.nun
```

`capture.sh` runs `bench.ML` and `bench2.ML` against a capture-only
component whose `nunchaku` saves the problem file it is handed and answers
`UNKNOWN` at once.  What comes out is exactly what Isabelle emits per
goal -- `<workdir>/capture-component/problems/pNNN.nun` -- plus
`<workdir>/goalmap.txt` mapping each file to its goal id, read off the
`RESULT` lines in call order.  No solver runs, so nothing depends on which
backend wins a race.

`dump_meta.sh` prints, per problem and per encoding branch, the two flags
the encoding pipeline computes:

- `sat_means_unknown` -- a model may be spurious, so it is marked and (by
  default) suppressed;
- `unsat_means_unknown` -- models were lost, so an `unsat` claims nothing
  and is reported as `UNKNOWN (INCOMPLETE ...)`.

Both are read straight from the pipeline, which is why the tool needs no
solver: the flags are set while the problem is encoded, before any backend
is called.  A problem is encoded once per branch of the pipeline and the
branches can disagree, so all three are printed: `cvc5` (shared with cvc4),
`kodkod` (shared with paradox) and `smbc`.  Which branch is asked matters:
on the benchmark as of the 0.5.3 certification, three goals carry
`unsat_means_unknown` in the `cvc5` branch and only one does in the `smbc`
branch.

Two things worth knowing before reading the output.  The goal numbering is
this run's own -- `p000` is the first goal `bench.ML` reports, whereas the
capture that the 0.5.3 spurious-model work quotes had a gold-test call at
`p000`, so its indices are one higher.  And `capture.sh` refuses to write
a goal map whose length differs from the number of captured files, since a
goal that never reached the tool would shift every later entry.
