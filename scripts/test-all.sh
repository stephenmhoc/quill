#!/usr/bin/env bash
# Everything before a commit, as fast as it goes: one build, the live tests once, then the UI
# tests on iPhone and iPad at the same time. Results land in build/results-*.xcresult.
set -euo pipefail
cd "$(dirname "$0")/.."
PHONE="iPhone 18 Pro"
PAD="iPad Pro 13-inch (M5)"
MATCHER=
cleanup() {
  [[ -n $MATCHER ]] && kill "$MATCHER" 2>/dev/null
  scripts/testenv.sh destroy >/dev/null 2>&1 || echo "Couldn't remove the test Ghost: run scripts/testenv.sh destroy" >&2
}
trap cleanup EXIT

# Ghost takes longer to come up than the app does to build, so do them together.
scripts/testenv.sh start > build/ghost.log 2>&1 &
GHOST=$!
xcodegen generate >/dev/null
for sim in "$PHONE" "$PAD"; do
  xcrun simctl boot "$sim" 2>/dev/null || true
  xcrun simctl bootstatus "$sim" -b >/dev/null
  xcrun simctl uninstall "$sim" com.merimerimeri.Quill 2>/dev/null || true
done
xcodebuild build-for-testing -project Quill.xcodeproj -scheme Quill \
  -destination "platform=iOS Simulator,name=$PHONE" -destination "platform=iOS Simulator,name=$PAD" \
  -derivedDataPath build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= > build/build.log 2>&1 \
  || { grep -E "error:" build/build.log; exit 1; }
wait "$GHOST" || { cat build/ghost.log; exit 1; }

set -a; . .dev/ghost-dev.env; set +a
export TEST_RUNNER_GHOST_DEV_URL="$GHOST_DEV_URL" TEST_RUNNER_GHOST_DEV_ADMIN_KEY="$GHOST_DEV_ADMIN_KEY"
if [[ -f .dev/microblog.env ]]; then
  set -a; . .dev/microblog.env; set +a
  export TEST_RUNNER_MICROBLOG_TOKEN="$MICROBLOG_TOKEN"
fi

# Enrol Face ID, then keep "looking at the phone" on both while the tests run.
for sim in "$PHONE" "$PAD"; do
  for _ in {1..30}; do
    xcrun simctl spawn "$sim" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 2>/dev/null && break
    sleep 1
  done
  xcrun simctl spawn "$sim" notifyutil -p com.apple.BiometricKit.enrollmentChanged
done
( while true; do
    for sim in "$PHONE" "$PAD"; do xcrun simctl spawn "$sim" notifyutil -p com.apple.BiometricKit_Sim.pearl.match >/dev/null 2>&1; done
    sleep 2
  done ) &
MATCHER=$!
disown

run() { # sim, name, xcodebuild arguments
  local sim=$1 name=$2; shift 2
  rm -rf "build/results-$name.xcresult"
  xcodebuild test-without-building -project Quill.xcodeproj -scheme Quill \
    -destination "platform=iOS Simulator,name=$sim" -derivedDataPath build \
    -resultBundlePath "build/results-$name.xcresult" -collect-test-diagnostics never "$@" > "build/$name.log" 2>&1
}

# They share one Ghost and count what's in it, so they go first and alone.
run "$PHONE" live -only-testing:QuillTests || { grep -E "✘|error:" build/live.log; exit 1; }
xcrun simctl uninstall "$PHONE" com.merimerimeri.Quill 2>/dev/null || true

run "$PHONE" iphone -only-testing:QuillUITests & PHONE_RUN=$!
run "$PAD" ipad -only-testing:QuillUITests & PAD_RUN=$!
status=0
wait "$PHONE_RUN" || status=1
wait "$PAD_RUN" || status=1
for name in iphone ipad; do
  grep -E "error:|Executed [0-9]+ tests?|TEST EXECUTE (SUCCEEDED|FAILED)" "build/$name.log" | tail -3 | cut -c1-200
  stalls=$(grep -c "animations complete notification not received" "build/$name.log" || true)
  echo "$name: $stalls stalled steps"
done
exit $status
