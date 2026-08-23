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
| `bench.ML`, `bench2.ML` | benchmark drivers (78 goals total: Main-library classes + custom-datatype/large-witness classes), driven by env vars `BENCH_ENGINE` (nitpick \| nunchaku \| nunchaku_smbc) and `BENCH_TIER` (seconds) |
| `truthcheck.ML` | side-check that the goals labelled true are actually provable |
| `DTBench.thy`, `DTBenchCheck.thy` | the custom datatypes for `bench2.ML`, and their sanity check |
| `NunGold.thy` | gold smoke test; loads in seconds, asserts programmatically, prints `GOLD_OK` |
| `aggregate.py`, `aggregate2.py` | fold `RESULT` lines from the logs into `results*.tsv` + summaries |
| `run.sh <workdir>` | run everything against the component under test |
| `gate.sh <workdir>` | pass/fail verdict of the fresh TSVs against `baseline/` |
| `baseline/` | checked-in reference TSVs and summaries |
| `bash_server_main.scala` | helper needed by both engines (below) |

Data format: each benchmark line is
`RESULT\tclass\tid\ttruth\tengine\ttier\tverdict\tms`, ending with
`BENCH_DONE`.  The `truth` column is the truth label (`F` = a countermodel
is expected, `T` = the goal is a true proposition); `gate.sh` reads its
drift rules and the spurious-verdict rule from this column and needs no
other source of truth.

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
assembled one):

- `x86_64-linux/nunchaku-bin` — the freshly built `nunchaku.exe`;
- `x86_64-linux/solvers/cvc5` — a static cvc5 **≥ 1.3.1** (the backend
  sends `get-model-domain-elements`, which older cvc5 answers with an
  error);
- substitute `@NUNCHAKU_VERSION@` in `etc/settings` with the content of
  the repository's `VERSION` file.

smbc comes from the Isabelle distribution (`contrib/smbc-*`); the frontend
puts it on the PATH itself.

## 3. Gold test (seconds; before anything else)

```bash
./regress/run.sh <workdir> gold
```

`NunGold.thy` raises on failure and prints `GOLD_OK` on success.  It
asserts: verdict `genuine` on the false goal, model actually displayed,
wall clock within cap, and a true goal not refuted.  (Alternative: load
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
`NUNCHAKU_HOME` resolves to the component under test.  It never runs
`isabelle build`.

Gate rules (also in `gate.sh`'s header): spurious verdicts on
true-labelled goals hard-fail at any tier; the 5 s tier must match the
baseline cell-for-cell, with `none/unknown → genuine` allowed only on
false-labelled goals; the 1 s tier is reported, not gated; timings are
advisory (3× median ratchet).

Run on a **quiet machine**.  A few Nitpick cells sit just under the 5 s
budget (`ls7` and `d11` finish around 4.6 s), and concurrent load tips
them from `none` into `unknown`, failing the 5 s identity check for a
reason that has nothing to do with the build under test (measured: both
flipped under load, both matched the baseline on a quiet re-run).  If
only such near-budget Nitpick cells differ, re-run those arms quietly
before drawing any conclusion.

If the run improved on the baseline (allowed drifts only), refresh
`baseline/` from the new TSVs in the same commit that explains why.

## 5. Release

Follow `RELEASE_CHECKLIST.md` in the packaging repository
(`isabelle-packaging-ci`); versions come from the `VERSION` file at the
repository root and are never written by hand.
