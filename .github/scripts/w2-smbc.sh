#!/bin/bash
# W2 probe: build smbc in the same Isabelle switch.  0.4.1 is the version our
# regression baseline certifies; fall back to the newest that builds and
# report what was actually installed.
set -euo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

SECONDS=0
if "$ISA" env bash -c 'isabelle_opam install -y smbc.0.4.1'; then
  echo "SMBC-INSTALLED: 0.4.1"
else
  echo "smbc.0.4.1 failed to install; available versions:"
  "$ISA" env bash -c 'isabelle_opam show smbc' || true
  echo "trying latest smbc"
  "$ISA" env bash -c 'isabelle_opam install -y smbc'
  echo "SMBC-INSTALLED: latest (see opam list below)"
fi
echo "PHASE smbc OK in ${SECONDS}s"

"$ISA" env bash -c 'isabelle_opam list' | grep -Ei 'smbc|msat|tip-parser|containers' || true

# locate the binary and stage it for artifacts + smoke
BIN="$("$ISA" env bash -c 'echo "$ISABELLE_OPAM_ROOT/$ISABELLE_OCAML_VERSION/bin"' | tail -1)"
ls -la "$BIN" | grep -i smbc
mkdir -p artifacts
if [ -f "$BIN/smbc.exe" ]; then
  cp "$BIN/smbc.exe" artifacts/smbc.exe
else
  cp "$BIN/smbc" artifacts/smbc.exe
fi
file artifacts/smbc.exe
