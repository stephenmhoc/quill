#!/usr/bin/env bash
# App tests in the simulator. With .dev/ghost-dev.env and the tunnel up, the Publisher
# suite runs against the dev Ghost:  ssh -N -L 2369:127.0.0.1:2369 docker-server
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .dev/ghost-dev.env ]]; then
  set -a; . .dev/ghost-dev.env; set +a
  export TEST_RUNNER_GHOST_DEV_URL="$GHOST_DEV_URL" TEST_RUNNER_GHOST_DEV_ADMIN_KEY="$GHOST_DEV_ADMIN_KEY"
fi
xcodegen generate >/dev/null
xcodebuild test -project Quill.xcodeproj -scheme Quill \
  -destination "platform=iOS Simulator,name=${SIM:-iPhone 18 Pro}" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO "$@"
