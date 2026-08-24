#!/usr/bin/env python3
"""Aggregate RESULT lines from benchmark logs into a TSV + per-class summaries.

Usage: aggregate.py <workdir> <log-prefix> <output-tsv-name>
  e.g. aggregate.py /path/to/work out_  results.tsv            (Main-library part)
       aggregate.py /path/to/work out2_ results_datatypes.tsv  (datatype part)

RESULT line format (see bench.ML):
  RESULT\tclass\tid\ttruth\tengine\ttier\tverdict\tms\tmodel
The summary is printed to stdout.
"""
import glob, os, statistics, sys

work, prefix, out_name = sys.argv[1], sys.argv[2], sys.argv[3]

rows = []
for log in sorted(glob.glob(os.path.join(work, prefix + "*.log"))):
    for line in open(log, encoding="utf-8", errors="replace"):
        if line.startswith("RESULT\t"):
            f = line.rstrip("\n").split("\t")[1:]
            cls, gid, truth, engine, tier, verdict, ms = f[:7]
            model = f[7] if len(f) > 7 else "na"
            rows.append((cls, gid, truth, engine, int(tier), verdict, int(ms), model))

with open(os.path.join(work, out_name), "w") as f:
    f.write("class\tgoal_id\ttruth\tengine\ttier\tverdict\tms\tmodel\n")
    for r in rows:
        f.write("\t".join(map(str, r)) + "\n")

# classes in first-seen order (the goal list's own order)
classes = list(dict.fromkeys(r[0] for r in rows))
engines = sorted({r[3] for r in rows})
tiers = sorted({r[4] for r in rows})

print("== Per class x engine x tier ==")
hdr = ("class", "engine", "tier", "nF", "genuine", "quasi", "potential", "none/unk",
       "err/toG", "nT", "SPURIOUS", "modelMiss", "medianMs", "p90Ms")
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
            modelmiss = sum(1 for r in sel if r[7] == "no")
            ts = sorted(r[6] for r in sel)
            med = int(statistics.median(ts))
            p90 = ts[max(0, int(len(ts) * 0.9) - 1)]
            print(f"{cls}\t{eng}\t{tier}\t{len(F)}\t{gen}\t{quasi}\t{pot}\t{noneunk}"
                  f"\t{err}\t{len(T)}\t{spurious}\t{modelmiss}\t{med}\t{p90}")

print()
print("== Overall (false goals: genuine-rate; true goals: spurious count; model losses) ==")
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
        modelmiss = [r for r in sel if r[7] == "no"]
        ts = sorted(r[6] for r in sel)
        med = int(statistics.median(ts)) if ts else 0
        print(f"{eng}\t{tier}s\tgenuine {gen}/{len(F)} (+{quasi} quasi)"
              f"\tSPURIOUS {len(spurious)}\tmodelMiss {len(modelmiss)}\tmedian {med}ms")
        for r in spurious:
            print(f"  !! SPURIOUS: {r[1]} ({r[0]})")
        for r in modelmiss:
            print(f"  !! MODEL MISSING: {r[1]} ({r[0]}) verdict={r[5]}")
