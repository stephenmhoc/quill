#!/usr/bin/env bash
# GhostKit tests, including the live suite against a fresh test Ghost, deleted when the run ends.
# KEEP_GHOST=1 leaves it running. See TESTING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
cleanup() {
  [[ -n ${KEEP_GHOST:-} ]] || (cd "$ROOT" && scripts/testenv.sh destroy >/dev/null 2>&1) || echo "Couldn't remove the test Ghost: run scripts/testenv.sh destroy" >&2
}
ROOT=$PWD
trap cleanup EXIT
scripts/testenv.sh start
set -a; . .dev/ghost-dev.env; set +a
cd Packages/GhostKit
swift test "$@"
