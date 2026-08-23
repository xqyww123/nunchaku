#!/usr/bin/env bash
# Usage: gate.sh <workdir>
#
# Regression gate over the TSVs produced by run.sh, judged against the
# checked-in baseline (regress/baseline/).  Exit 0 = pass.
#   - Any true-labelled goal claimed refuted (genuine/quasi_genuine), any
#     tier: hard fail, no exceptions.
#   - 5 s tier: per-(goal, engine) verdict must equal the baseline.  The
#     only drift allowed is none/unknown -> genuine on FALSE-labelled
#     goals (a solver got better); on true-labelled goals that same drift
#     is precisely a misrefutation and hard-fails via the rule above.
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

def load(path):
    rows = {}
    with open(path) as f:
        f.readline()  # header
        for line in f:
            cls, gid, truth, engine, tier, verdict, ms = line.rstrip("\n").split("\t")
            rows[(gid, engine, int(tier))] = (truth, verdict, int(ms))
    return rows

for name in ("results.tsv", "results_datatypes.tsv"):
    base = load(os.path.join(base_dir, name))
    new = load(os.path.join(work, name))

    for (gid, engine, tier), (truth, verdict, _) in sorted(new.items()):
        if truth == "T" and verdict in REFUTED:
            err(f"{name}: SPURIOUS: true goal {gid} judged {verdict} ({engine}, {tier}s)")

    for key, (truth, bverdict, _) in sorted(base.items()):
        gid, engine, tier = key
        if key not in new:
            if tier == 5:
                err(f"{name}: cell {gid}/{engine}/5s missing from the new run")
            continue
        verdict = new[key][1]
        if verdict == bverdict:
            continue
        drift = f"{name}: {gid}/{engine}/{tier}s: {bverdict} -> {verdict}"
        if tier != 5:
            print("report (1s tier, not gated):", drift)
        elif truth == "F" and bverdict in ("none", "unknown") and verdict == "genuine":
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
