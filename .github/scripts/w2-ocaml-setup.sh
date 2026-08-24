#!/bin/bash
# W2 probe: opam init + OCaml 4.14.1 switch via Isabelle's own convention
# (isabelle ocaml_setup_base).  ocaml_setup would additionally install
# zarith; nunchaku/smbc need no zarith, so the base setup is the right tool.
set -euo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"

echo "== settings =="
"$ISA" getenv ISABELLE_PLATFORM64 ISABELLE_OPAM ISABELLE_OPAM_ROOT \
  ISABELLE_OCAML_VERSION ISABELLE_HOME_USER

# The opam component of the distribution may not ship an x86_64-cygwin opam
# (its README says Windows needs the separate Cygwin "opam" package, which the
# previous workflow step installed).  Point ISABELLE_OPAM at it if so.
OPAMBIN="$("$ISA" getenv -b ISABELLE_OPAM)"
if [ ! -e "$OPAMBIN" ] && [ ! -e "$OPAMBIN.exe" ]; then
  IHU="$("$ISA" getenv -b ISABELLE_HOME_USER)"
  mkdir -p "$IHU/etc"
  if ! grep -q ISABELLE_OPAM "$IHU/etc/settings" 2>/dev/null; then
    echo 'ISABELLE_OPAM="/usr/bin/opam"' >> "$IHU/etc/settings"
  fi
  echo "component opam missing at $OPAMBIN -- overriding with /usr/bin/opam"
  "$ISA" getenv ISABELLE_OPAM
fi

verify() {
  "$ISA" env bash -c \
    'isabelle_opam config exec --switch "$ISABELLE_OCAML_VERSION" -- ocaml -version'
}

SECONDS=0
if "$ISA" ocaml_setup_base && verify; then
  echo "PHASE ocaml_setup_base OK in ${SECONDS}s"
else
  echo "ocaml_setup_base or verification failed -- wiping opam root (possibly a"
  echo "broken cache restore) and rebuilding from scratch"
  rm -rf "$("$ISA" getenv -b ISABELLE_OPAM_ROOT)"
  SECONDS=0
  "$ISA" ocaml_setup_base
  verify
  echo "PHASE ocaml_setup_base (fresh) OK in ${SECONDS}s"
fi
