#!/usr/bin/env python3
"""Generate deeply nested canned smbc models.

Each family nests one syntactic construct [d] levels deep.  Before the
typed-unknown environment landed, every one of these took time exponential
in [d] to decode -- and all of it after smbc has already answered SAT, so
no deadline bounds it.  They are the wall-clock cells of the regression:
decoding must stay linear in model size.

  chain d  ->  (@ g_ (@ g_ ... ?u))            problems/chain.nun
  adv   d  ->  (@ g_ ... (?f ?x))              problems/chain.nun
  eqn   d  ->  (= (?f_{d-1} (= ... )) $a__0)   problems/distp.nun
  dist  d  ->  (distinct (distinct ... ) ?p)   problems/distp.nun
  match d  ->  (match (?f_i ...) ...)          problems/matchp.nun
  match_hp d -> the same, as a second entry     problems/headpos.nun

usage: gen_deep.py <family> <depth> <output-file>
"""
import sys

TYPES = "(type a_ ($a__0 $a__1))"


def model(entries):
    return "(result SAT\n  :model (%s))\n" % ("\n          ".join(entries),)


def build(kind, d):
    if kind == "chain":
        body = "?u"
        for _ in range(d):
            body = "(@ g_ %s)" % body
        return model([TYPES, "(val c_ %s)" % body])
    if kind == "adv":
        body = "(?f ?x)"
        for _ in range(d):
            body = "(@ g_ %s)" % body
        return model([TYPES, "(val c_ %s)" % body])
    if kind == "eqn":
        body = "$a__0"
        for i in range(d):
            body = "(= (?f%d %s) $a__0)" % (i, body)
        return model([TYPES, "(val c_ $a__0)", "(val q_ %s)" % body])
    if kind == "dist":
        body = "$a__0"
        for i in range(d):
            body = "(distinct %s ?p%d)" % (body, i)
        return model([TYPES, "(val c_ $a__0)", "(val q_ %s)" % body])
    if kind == "match":
        body = "?l0"
        for i in range(d):
            body = ("(match (?f%d %s) (case Nil_ $a__0) (case (Cons_ x1 x2) $a__0))"
                    % (i, body))
        return model([TYPES, "(val zz_ %s)" % body])
    if kind == "match_hp":
        # the scrutinee's type is only reachable through a *sibling* entry,
        # so this one also exercises order-independent recovery
        body = "?l0"
        for i in range(d):
            body = ("(match (?f%d %s) (case Nil_ Nil_) (case (Cons_ x1 x2) Nil_))"
                    % (i, body))
        return model([TYPES, "(val xs_ Nil_)", "(val ys_ %s)" % body])
    raise SystemExit("unknown family: %s" % kind)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    kind, depth, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    with open(out, "w") as f:
        f.write(build(kind, depth))
