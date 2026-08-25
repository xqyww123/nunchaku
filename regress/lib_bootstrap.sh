# Shared Isabelle bootstrap for the scripts in this directory.  Sourced, not
# executed; the caller sets REGRESS, WORK (absolute, existing), ISA and COMP,
# and runs with "set -eu".
#
# Two steps, in this order:
#
#   isabelle_env    isolates ISABELLE_HOME_USER under $WORK/fakehome, copies
#                   the real preferences into it, registers $COMP, exports
#                   HOME/USER_HOME, and refuses to go on unless the resulting
#                   NUNCHAKU_HOME and NUNCHAKU_VERSION are the ones under
#                   test.  It COPIES the preferences on purpose: a scratch
#                   user dir with default preferences can silently flip
#                   ML_system_64 and trigger an implicit 32-bit build, which
#                   is also why it asserts ML_system_64 afterwards.
#
#   bash_server     starts the bash server both engines need and sets ADDR
#                   and PW for the caller's ML_process invocations.  The
#                   server MUST live in the same HOME as the runs:
#                   bash_process expands "$NUNCHAKU_HOME" on the server side,
#                   so a server started from the real home would silently run
#                   the distribution's bundled 2017 binary instead of the
#                   component under test.  It is stopped on exit.
#
# Neither step ever runs "isabelle build".

die () { echo "${0##*/}: $*" >&2; exit 1; }

isabelle_env () {
  [ -x "$COMP/x86_64-linux/nunchaku" ] ||
    die "no executable $COMP/x86_64-linux/nunchaku"

  ISA_ID=$("$ISA" getenv -b ISABELLE_IDENTIFIER)
  REAL_PREFS="$HOME/.isabelle/$ISA_ID/etc/preferences"
  FAKE_ETC="$WORK/fakehome/.isabelle/$ISA_ID/etc"
  if [ ! -f "$FAKE_ETC/preferences" ]; then
    [ -f "$REAL_PREFS" ] ||
      die "$REAL_PREFS not found; refusing to run with default preferences"
    mkdir -p "$FAKE_ETC"
    cp "$REAL_PREFS" "$FAKE_ETC/preferences"
  fi
  printf 'ISABELLE_HEAPS="%s"\n' "$WORK/heaps" > "$FAKE_ETC/settings"
  printf '%s\n' "$COMP" > "$FAKE_ETC/components"

  export USER_HOME="$WORK/fakehome" HOME="$WORK/fakehome"

  ML64=$("$ISA" options -g ML_system_64)
  [ "$ML64" = true ] || die "ML_system_64=$ML64 (want true); aborting"
  NUNHOME=$("$ISA" getenv -b NUNCHAKU_HOME)
  [ "$NUNHOME" = "$COMP/x86_64-linux" ] ||
    die "NUNCHAKU_HOME=$NUNHOME does not point at $COMP/x86_64-linux"
  NUNVER=$("$ISA" getenv -b NUNCHAKU_VERSION)
  [ "$NUNVER" = "$(cat "$REGRESS/../VERSION")" ] && return 0
  echo "${0##*/}: NUNCHAKU_VERSION=$NUNVER does not match VERSION ($(cat "$REGRESS/../VERSION"))" >&2
  echo "        (was @NUNCHAKU_VERSION@ substituted when the component was assembled?)" >&2
  exit 1
}

bash_server () {
  rm -f "$WORK/bash_server_addr.txt"
  "$ISA" scala "$REGRESS/bash_server_main.scala" "$WORK/bash_server_addr.txt" \
    > "$WORK/bash_server.log" 2>&1 &
  BS_PID=$!
  trap 'kill "$BS_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 180); do
    grep -q BASH_SERVER_READY "$WORK/bash_server.log" 2>/dev/null && break
    kill -0 "$BS_PID" 2>/dev/null || break
    sleep 1
  done
  grep -q BASH_SERVER_READY "$WORK/bash_server.log" ||
    die "bash server failed to start, see $WORK/bash_server.log"
  ADDR=$(sed -n 1p "$WORK/bash_server_addr.txt")
  PW=$(sed -n 2p "$WORK/bash_server_addr.txt")
}
