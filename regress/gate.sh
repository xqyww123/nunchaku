#!/usr/bin/env bash
# Usage: gate.sh <workdir>
#
# Regression gate over the TSVs produced by run.sh, judged against the
# checked-in baseline (regress/baseline/).  Exit 0 = pass.
#   - Any true-labelled goal claimed refuted (genuine/quasi_genuine), any
#     tier: hard fail, no exceptions.
#   - 5 s tier: per-(goal, engine) verdict must equal the baseline, where
#     `none` and `unknown` count as ONE verdict (neither claims anything
#     about the goal; the distinction is exactly what near-budget
#     scheduling perturbs, and it flipped two Nitpick cells under machine
#     load before this rule).  The only drift allowed is
#     none/unknown -> genuine on FALSE-labelled goals (a solver got
#     better); on true-labelled goals that same drift is precisely a
#     misrefutation and hard-fails via the rule above.
#   - Model column, 5 s tier: a cell must not regress from model-shown
#     ("yes") to model-missing ("no") -- refuting verdicts survive the
#     smbc model-hole class of defects, so without this column the gate
#     is blind to them.
#   - 1 s tier: differences are reported, not gated (that tier is
#     scheduling-sensitive; it exists as an early-warning channel).
#   - Timing: advisory only -- warn when an engine's median exceeds 3x
#     the baseline median.
set -eu
REGRESS="$(cd "$(dirname "$0")" && pwd)"
WORK=${1:?usage: gate.sh <workdir>}
exec python3 - "$REGRESS/baseline" "$WORK" <<'EOF'
import os, statistics, sys

base_dir, work = sys.argv[1], sys.argv[2]
REFUTED = ("genuine", "quasi_genuine")
fail = False

def err(msg):
    global fail
    fail = True
    print("GATE FAIL:", msg)

def canon(v):
    # none and unknown make the same claim: "did not refute"
    return "none/unknown" if v in ("none", "unknown") else v

def load(path):
    rows = {}
    with open(path) as f:
        f.readline()  # header
        for line in f:
            fs = line.rstrip("\n").split("\t")
            cls, gid, truth, engine, tier, verdict, ms = fs[:7]
            model = fs[7] if len(fs) > 7 else "na"
            rows[(gid, engine, int(tier))] = (truth, verdict, int(ms), model)
    return rows

for name in ("results.tsv", "results_datatypes.tsv"):
    base = load(os.path.join(base_dir, name))
    new = load(os.path.join(work, name))

    for (gid, engine, tier), (truth, verdict, _, _) in sorted(new.items()):
        if truth == "T" and verdict in REFUTED:
            err(f"{name}: SPURIOUS: true goal {gid} judged {verdict} ({engine}, {tier}s)")

    for key, (truth, bverdict, _, bmodel) in sorted(base.items()):
        gid, engine, tier = key
        if key not in new:
            if tier == 5:
                err(f"{name}: cell {gid}/{engine}/5s missing from the new run")
            continue
        _, verdict, _, model = new[key]

        if bmodel == "yes" and model == "no":
            drift = f"{name}: {gid}/{engine}/{tier}s: model was shown, now missing (verdict {verdict})"
            if tier == 5:
                err(drift)
            else:
                print("report (1s tier, not gated):", drift)

        if canon(verdict) == canon(bverdict):
            continue
        drift = f"{name}: {gid}/{engine}/{tier}s: {bverdict} -> {verdict}"
        if tier != 5:
            print("report (1s tier, not gated):", drift)
        elif truth == "F" and canon(bverdict) == "none/unknown" and verdict == "genuine":
            print("note: allowed drift:", drift)
        else:
            err(drift)

    for engine in sorted({k[1] for k in base}):
        for tier in (1, 5):
            bt = [v[2] for k, v in base.items() if k[1:] == (engine, tier)]
            nt = [v[2] for k, v in new.items() if k[1:] == (engine, tier)]
            if bt and nt:
                bm, nm = statistics.median(bt), statistics.median(nt)
                if bm > 0 and nm > 3 * bm:
                    print(f"advisory: {name}: {engine}/{tier}s median {nm}ms > 3x baseline {bm}ms")

print("GATE", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
EOF
