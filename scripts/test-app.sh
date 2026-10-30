#!/usr/bin/env bash
# E2E tests in the simulator against a fresh test Ghost, deleted when the run ends.
# KEEP_GHOST=1 leaves it running to look around afterwards. See TESTING.md.
# SIM picks the device, e.g. SIM="iPad Pro 13-inch (M5)" scripts/test-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${SIM:-iPhone 18 Pro}"
MATCHER=
cleanup() {
  [[ -n $MATCHER ]] && kill "$MATCHER" 2>/dev/null
  [[ -n ${KEEP_GHOST:-} ]] || scripts/testenv.sh destroy >/dev/null 2>&1 || echo "Couldn't remove the test Ghost: run scripts/testenv.sh destroy" >&2
}
trap cleanup EXIT
scripts/testenv.sh start
set -a; . .dev/ghost-dev.env; set +a
export TEST_RUNNER_GHOST_DEV_URL="$GHOST_DEV_URL" TEST_RUNNER_GHOST_DEV_ADMIN_KEY="$GHOST_DEV_ADMIN_KEY"

xcodegen generate >/dev/null
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl uninstall "$SIM" com.merimerimeri.Quill 2>/dev/null || true

# Enrol Face ID, then keep "looking at the phone" while the tests run.
# A simulator that's just booted can take a moment to accept commands.
for _ in {1..30}; do
  xcrun simctl spawn "$SIM" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 2>/dev/null && break
  sleep 1
done
xcrun simctl spawn "$SIM" notifyutil -p com.apple.BiometricKit.enrollmentChanged
( while true; do xcrun simctl spawn "$SIM" notifyutil -p com.apple.BiometricKit_Sim.pearl.match >/dev/null 2>&1; sleep 2; done ) &
MATCHER=$!

rm -rf build/results.xcresult
xcodebuild test -project Quill.xcodeproj -scheme Quill \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath build -resultBundlePath build/results.xcresult -collect-test-diagnostics never \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= "$@"
