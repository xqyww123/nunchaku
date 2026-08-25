# Case corpus for the smbc model parser

This directory holds *inputs only*: the problems, the canned smbc answers,
and the generator for the deep ones.  There are deliberately no dune rules
and no expected-output files yet.  The shared driver
(`regress/support/run_case`) is being written on another line, and the
golden expectations are generated once every code change of this release
has landed — the release moves `?__<n>` identities and warning texts, so
generating them earlier only means regenerating them later.

## Layout

| path | what it is |
| --- | --- |
| `problems/*.nun` | the problems nunchaku is asked to solve |
| `models/*.txt` | canned smbc answers, fed to nunchaku as smbc's stdout |
| `gen_deep.py` | generator for the deeply nested models |
| `cases.tsv` | the manifest: case → model, problem, deadline, expectation |

A case is run by pointing `NUNCHAKU_SMBC` at a stub that ignores its stdin
and prints the model file, then running nunchaku on the problem:

```sh
cat > stub.sh <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
cat "$STUB_MODEL"
EOF
chmod +x stub.sh
STUB_MODEL=models/m_cross.txt NUNCHAKU_SMBC=./stub.sh \
  nunchaku --solvers smbc --timeout 60 problems/two.nun
```

## The `?__<n>` and `v_N/M` contract

Model output contains two kinds of generated number, and **neither is
stable**:

- `?__<n>` is the process-global `ID.id` counter of the unknown's id. It
  identifies one unknown *within one printed model* — two occurrences of
  `?__46` are the same unknown, `?__46` and `?__47` are different ones —
  and nothing more. The value depends on how many ids the pipeline happened
  to allocate before reaching the model, so it moves when unrelated code
  changes.
- `v_<n>/<m>` is a generated variable name plus its id counter, with the
  same property.

Golden comparison must therefore normalise both. Two further rules, each
learned the hard way:

1. Normalising to a single token (`?__[0-9]+` → `?__N`) is **necessary but
   not sufficient**: the pretty printer wraps on the *pre-normalisation*
   column width, so `v_0/8299` and `v_0/133` produce different line breaks
   from identical token streams. Collapse whitespace as well, or set an
   effectively infinite `Format.pp_set_margin` for golden runs, or compare
   the `-o sexp` form.
2. Entry order carries no meaning. The two model printers list entries in
   opposite orders and only one of them is now used; no comparison may
   encode either order.

## The cases, and what each is for

"Expectation" below is the word used in `cases.tsv`.

### recovered — the unknown gets a type and prints as `?__<n>`

- **m_one** — the minimal one-application model `(val c_ (@ g_ ?u))`.
  `?u` is the argument of a known function, so its type comes from that
  function's domain: `val c_ := g_ ?__N`. Guards against "optimisations"
  of the application path that lose this recovery and turn `g_ ?__N` back
  into the opaque `g_ (?__ ?u)`, which costs Isabelle the whole model
  block.
- **m_cross** / **m_cross2** — the *same* model with two entries in the
  two possible orders. `(= ?w1 ?w2)` appears in one entry and `?w1`'s type
  is fixed by the other. Both orders must recover both unknowns and
  produce the *same* output. This pair is the order-independence test; it
  is the reason the corpus contains an apparent duplicate.
- **m_defonly2** — `?l1` appears both as the argument of `Cons_` (which
  types it) and as the scrutinee of a match with only a `default` branch
  (which does not). The typing entry comes first. Both entries must come
  out complete.
- **m_headpos** — an unknown in head position, plus unknowns under `if`
  and under a match. The general recovery case.
- **m_matchval** — a function value whose body is a match on its argument.
  Included for the printer, not the parser: see "known reader gap" below.
- **m_eqn_24**, **m_dist_28**, **m_chain_4000**, **m_match_hp_22** — the
  deep ones. Each nests one construct (`=`, `distinct`, `@`, `match`) and
  each used to cost time exponential in the depth, spent *after* smbc had
  already answered SAT and therefore outside every deadline: 32.6 s at
  `eqn` depth 24, 56.7 s at `dist` depth 28, over 60 s for a linear chain
  of 250 applications. They now finish in hundredths of a second, and the
  deadline column in `cases.tsv` is what pins that. `m_dist_28` needs no
  unknown at all — it is pure decoding cost.
- **real_part_app** — captured verbatim from real smbc 0.6.1 on
  `problems/part_app.nun`. Contains a genuine unknown (`?prop_9`) inside a
  lambda body, recovered as `?__<n>`. The corpus needs at least one answer
  no one wrote by hand.

### opaque — no type is determined, and that is the honest answer

- **m_uau** — `(val xs_ (?f ?g))`: an unknown applied to an unknown.
  Nothing in the model determines either type, so the output keeps the
  opaque `(?__ ?f) (?__ ?g)`. This is the boundary of what any of the
  mechanisms considered can do; it must not be promised away.
- **m_adv_36**, **m_adv_48** — the same shape at the bottom of a 36- and
  48-deep application chain. The chain is decoded, the hole at the bottom
  stays opaque, and the whole run must still fit the deadline. These are
  wall-clock cells whose *content* is the opaque case.

### conflict — one identity, two types

- **m_classconf** — `?w1` is used at type `a_` in one entry and `?w2` at
  type `b_` in another, and a third entry says `(= ?w1 ?w2)`. The two
  unknowns are therefore in one class with two incompatible types. Expect:
  exactly **one** warning naming the unknown by its smbc name
  (`unknown ?w2 recovered at two types: b_ and a_`), and every occurrence
  of the class printed as `?__unparsable <ty>` — never one identity
  standing for both types. This model then fails decision-tree
  conversion for an unrelated reason, so the run ends as
  `UNKNOWN (BACKEND_ERROR …)` with exit 0; that is the case below.
- **poison_untyped** — the same conflict, but reached in the order that
  leaves the occurrences *untyped at conversion time*: the entry holding
  `(= ?w1 ?w2)` is read first, and the two entries that type the class come
  after. An occurrence like this used to escape the poisoning and print as
  the opaque `?__ ?w1` — the very token `?__unparsable` exists to avoid,
  since it costs Isabelle the whole model block. Expect no opaque hole
  anywhere in the output.
- **eq_app_bare** — `?f` used both bare and applied in one equation, so the
  class holds `a_ -> a_` and `a_ -> a_ -> a_`. Both occurrences must be
  poisoned, including the applied one, whose arguments are kept:
  `(?__unparsable a_ -> a_) $a__0`.
- **eq_arity_conf** — `?f` applied at two different arities. Same
  expectation. Worth knowing what this looked like before the release: it
  printed `?__40 $a__0 $a__0` with `?__40 : a_ -> a_`, i.e. one identity at
  one type applied at another — an ill-typed model, silently.

A note on all four: two occurrences of one poisoned class that end up with
the same type print as the same term, and `dt_of_term` then decides
`(= x x)` structurally and folds the enclosing `if` to its `then` branch.
That folding is not new and is not specific to holes — pristine nunchaku
folds `(if (= $b__0 $b__0) then a else b)` to `a` in the same place — but a
reader of `poison_untyped`'s output should know that is where the `if`
went.

### contained — the entry is lost, nothing else is

- **m_defonly3** — the same two entries as `m_defonly2` in the other
  order, so the match-with-only-a-default is read before anything types
  `?l1`. Nothing can name the scrutinee's datatype. Expect a warning, that
  one entry as `val xs_ := (?__unparsable list_)`, and a complete `SAT`
  answer carrying every other entry, exit 0. Before this release the same
  model aborted the run with `undefined ID: ?l1` and exit 1.
- **m_defonly** — the same shape on a problem with no datatype at all.
- **m_match_22** — 22 nested matches on a datatype that is *not part of
  the problem sent to smbc* (`matchp.nun` declares `list_` but never uses
  it, so it is pruned before smbc sees it). The branch names therefore do
  not resolve to constructors and the datatype cannot be found. Expect the
  same containment, within the deadline.
- **cast** — a TIP cast, `(as ?u a_)`, in a value. smbc 0.6.1 does not
  emit one, but the parser used to `assert false` on it, which ends the
  process rather than the entry. Expect a warning naming the cast and
  `val c_ := (?__unparsable a_)`.
- **ite_lambda_mismatch** — one value whose two `if` branches are lambdas
  binding *different* types. The code that hoists the lambda out of the
  branches assumed well-typedness and asserted; the model is smbc's, so it
  reports instead. This one is not contained per entry — the hoisting runs
  after the entries are converted — so expect
  `UNKNOWN (BACKEND_ERROR …)` naming both types, exit 0.
- **real_multi** — captured verbatim from real smbc 0.6.1 on
  `problems/multi.nun`. Its value for `k_` is a match on a *computed*
  scrutinee (`x0 G_`, not a variable), which the decision-tree conversion
  cannot represent. Expect `UNKNOWN (BACKEND_ERROR …)` and exit 0 — not a
  fatal error, because a defect in one backend's output must not stop the
  others. This is a real-corpus witness for exactly that change, and also
  a standing reminder that the decision-tree conversion has its own gap.

## Generating the deep models

`gen_deep.py <family> <depth> <out>`; families `chain`, `adv`, `eqn`,
`dist`, `match`, `match_hp`. The staged files are the depths listed in
`cases.tsv`; the linear-chain scaling check (250 / 500 / 1000 / 2000 /
4000) is generated on demand:

```sh
for d in 250 500 1000 2000 4000; do
  python3 gen_deep.py chain $d /tmp/m_chain_$d.txt
done
```

Decoding is linear in model size: those five ran in
0.02 / 0.03 / 0.04 / 0.10 / 0.27 s (16× the size for 13× the time, most of
it the printer), where the pre-release binary exceeded 60 s at every one.

## Known reader gap, recorded not fixed

`m_matchval` parses and prints fine, but what it prints is
`match v_0/54 with | Cons_ y z -> … | Nil_ -> … end`, and Isabelle's model
parser (`nunchaku_model.ML`, `parse_tm`) has no production for `match`,
`with`, `|` or `end`. A model containing a datatype-scrutinee function
value is therefore unreadable by the Isabelle frontend — it costs the
model display, not the verdict. Out of scope for this release; the case is
staged so that whoever fixes it has a witness.
