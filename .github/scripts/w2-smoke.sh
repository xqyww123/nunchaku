#!/bin/bash
# W2 probe: smoke the cygwin-ABI nunchaku.exe under the bundled Cygwin, with
# the pinned cvc5 (native Windows binary) and the self-built smbc.
set -uo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

NUN=./artifacts/nunchaku.exe
export NUNCHAKU_CVC5="$WS/solvers/cvc5.exe"
export NUNCHAKU_SMBC="$WS/artifacts/smbc.exe"
fail=0

echo "== --version =="
"$NUN" --version || fail=1

run_gold() { # name, extra solver args...
  local name="$1"; shift
  echo
  echo "== gold.nun with $* =="
  SECONDS=0
  "$NUN" --skolems-in-model --no-color --no-specialize "$@" --timeout 30 \
    regress/gold.nun > "smoke-$name.out" 2> "smoke-$name.err"
  local rc=$?
  echo "exit=$rc wall=${SECONDS}s"
  echo "--- stdout (verbatim) ---"; cat "smoke-$name.out"
  echo "--- stderr ---"; cat "smoke-$name.err"
  return $rc
}

run_gold cvc5 --solvers cvc5
grep -q '^SAT' smoke-cvc5.out && grep -q '{backend:cvc5' smoke-cvc5.out \
  || { echo "SMOKE-FAIL: cvc5 run did not produce SAT + {backend:cvc5"; fail=1; }

run_gold smbc --solvers smbc
# gold.nun with smbc exercises the model-unknown path: any definite answer
# line counts as "smbc responded"; report is verbatim above either way.
grep -Eq '^(SAT|UNSAT|UNKNOWN|TIMEOUT)' smoke-smbc.out \
  || { echo "SMOKE-FAIL: smbc run produced no answer"; fail=1; }

run_gold combined --solvers cvc5,smbc
grep -q '^SAT' smoke-combined.out \
  || { echo "SMOKE-FAIL: combined run did not produce SAT"; fail=1; }

echo
echo "== DLL footprint (cygcheck) =="
cygcheck ./artifacts/nunchaku.exe || fail=1
cygcheck ./artifacts/smbc.exe || true
echo
echo "== binary sizes =="
ls -la artifacts/ solvers/

exit $fail
