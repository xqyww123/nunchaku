Skeleton of the Isabelle component `isabelle-nunchaku` ships.  Packaging
(in a separate repository) adds to this skeleton:

  x86_64-linux/nunchaku-bin   the static nunchaku binary built by CI
  x86_64-linux/solvers/cvc5   official static cvc5 release (>= 1.3.1)
  COMMIT                      full 40-char SHA this build was made from
  LICENSE, LICENSE-cvc5       license texts

and substitutes @NUNCHAKU_VERSION@ in etc/settings from the VERSION file
at the repository root (versions are never written by hand).
