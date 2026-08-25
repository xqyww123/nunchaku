Skeleton of the Isabelle component `isabelle-nunchaku` ships.  This directory is
not itself a component: it is the part of one that does not depend on the
platform.  Packaging (in a separate repository) creates the single platform
directory the package is for and fills it in.

A built package covers exactly one platform `<PLAT>`, one of

    x86_64-linux  arm64-linux  x86_64-darwin  arm64-darwin  x86_64-cygwin

(Isabelle's own platform identifiers, from `lib/scripts/isabelle-platform` in
the distribution -- the same strings the fork's CI uses to name its release
assets, so the asset name and the directory name cannot drift apart), and looks
like this:

  etc/settings                from `etc/settings` here, with `@NUNCHAKU_VERSION@`
                              replaced by the repository's `VERSION` file and
                              `@NUNCHAKU_PLATFORM@` by `<PLAT>` (versions and
                              platforms are never written by hand)
  <PLAT>/nunchaku             from `./nunchaku` here -- ONE wrapper text, copied
                              into whichever platform directory this package is
                              for.  It resolves its own directory at run time, so
                              it needs no platform knowledge and there is no
                              per-platform variant of it to keep in step.
  <PLAT>/nunchaku-bin         the nunchaku binary built by the fork's CI
                              (`nunchaku-bin.exe` on `x86_64-cygwin`)
  <PLAT>/solvers/cvc5         official static cvc5 release (>= 1.3.1)
  <PLAT>/solvers/smbc         smbc 0.6.1, built by the fork's CI from
                              `github.com/c-cube/smbc` tag `v0.6.1`
  COMMIT                      full 40-char SHA this build was made from
  LICENSE, LICENSE-cvc5       license texts

Why `etc/settings` names the platform through a placeholder rather than picking
one at run time from `$ISABELLE_PLATFORM64`: a package contains exactly one
platform directory, and substituting its literal name makes it structurally
impossible for `NUNCHAKU_HOME` to point at a directory the package does not
contain.  A run-time dispatch would still be *correct*, but it would leave that
failure mode open -- and on Apple Silicon it would have to know that
`ISABELLE_APPLE_PLATFORM64` overrides `ISABELLE_PLATFORM64`.
