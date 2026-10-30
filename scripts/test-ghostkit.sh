#!/usr/bin/env bash
# Run GhostKit tests. If .dev/ghost-dev.env exists (see dev-ghost-seed.sh), the live
# suite runs against the dev Ghost; start the tunnel first:
#   scripts/testenv.sh up
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .dev/ghost-dev.env ]]; then set -a; . .dev/ghost-dev.env; set +a; fi
cd Packages/GhostKit
swift test "$@"
