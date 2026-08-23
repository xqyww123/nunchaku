#!/usr/bin/env python3
"""Aggregate RESULT lines from benchmark logs into a TSV + per-class summaries."""
import glob, os, statistics, sys

SCRATCH = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
rows = []
for log in sorted(glob.glob(os.path.join(SCRATCH, "out_*.log"))):
    for line in open(log, encoding="utf-8", errors="replace"):
        if line.startswith("RESULT\t"):
            _, cls, gid, truth, engine, tier, verdict, ms = line.rstrip("\n").split("\t")
            rows.append((cls, gid, truth, engine, int(tier), verdict, int(ms)))

with open(os.path.join(SCRATCH, "results.tsv"), "w") as f:
    f.write("class\tgoal_id\ttruth\tengine\ttier\tverdict\tms\n")
    for r in rows:
        f.write("\t".join(map(str, r)) + "\n")

def pct(n, d):
    return "-" if d == 0 else f"{100*n/d:.0f}%"

engines = sorted({r[3] for r in rows})
tiers = sorted({r[4] for r in rows})
classes = ["arith_lin", "arith_nl", "list", "opt", "set", "quant", "exwrap", "ho"]

print("== Per class x engine x tier ==")
hdr = ("class", "engine", "tier", "nF", "genuine", "quasi", "potential", "none/unk", "err/toG",
       "nT", "SPURIOUS", "medianMs", "p90Ms")
print("\t".join(hdr))
for cls in classes:
    for eng in engines:
        for tier in tiers:
            sel = [r for r in rows if r[0] == cls and r[3] == eng and r[4] == tier]
            if not sel:
                continue
            F = [r for r in sel if r[2] == "F"]
            T = [r for r in sel if r[2] == "T"]
            gen = sum(1 for r in F if r[5] == "genuine")
            quasi = sum(1 for r in F if r[5] == "quasi_genuine")
            pot = sum(1 for r in F if r[5] == "potential")
            noneunk = sum(1 for r in F if r[5] in ("none", "unknown"))
            err = sum(1 for r in F if r[5].startswith("error") or r[5] == "guard_timeout")
            spurious = sum(1 for r in T if r[5] in ("genuine", "quasi_genuine"))
            ts = sorted(r[6] for r in sel)
            med = int(statistics.median(ts))
            p90 = ts[max(0, int(len(ts)*0.9) - 1)]
            print(f"{cls}\t{eng}\t{tier}\t{len(F)}\t{gen}\t{quasi}\t{pot}\t{noneunk}\t{err}\t{len(T)}\t{spurious}\t{med}\t{p90}")

print()
print("== Overall (false goals: genuine-rate; true goals: spurious count) ==")
for eng in engines:
    for tier in tiers:
        sel = [r for r in rows if r[3] == eng and r[4] == tier]
        if not sel:
            continue
        F = [r for r in sel if r[2] == "F"]
        T = [r for r in sel if r[2] == "T"]
        gen = sum(1 for r in F if r[5] == "genuine")
        quasi = sum(1 for r in F if r[5] == "quasi_genuine")
        spurious = [r for r in T if r[5] in ("genuine", "quasi_genuine")]
        ts = sorted(r[6] for r in sel)
        genF_ts = sorted(r[6] for r in F if r[5] == "genuine")
        med = int(statistics.median(ts))
        p90 = ts[max(0, int(len(ts)*0.9) - 1)]
        medg = int(statistics.median(genF_ts)) if genF_ts else -1
        print(f"{eng} tier={tier}s: false {gen}/{len(F)} genuine ({pct(gen,len(F))}), +{quasi} quasi; "
              f"SPURIOUS on true: {len(spurious)} {[r[1] for r in spurious]}; "
              f"median {med}ms p90 {p90}ms (median genuine-hit {medg}ms)")

print()
print("== Spurious detail (any true goal called genuine/quasi_genuine) ==")
for r in rows:
    if r[2] == "T" and r[5] in ("genuine", "quasi_genuine"):
        print("\t".join(map(str, r)))
