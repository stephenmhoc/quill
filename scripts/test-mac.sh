#!/usr/bin/env bash
# Mac UI tests. Ad-hoc signed, because the team-signed test runner hangs before it connects.
# Only ever clears the development build's data: never the Quill in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
readonly DEV_ID=com.merimerimeri.Quill.dev
xcodegen generate >/dev/null
built=$(xcodebuild -showBuildSettings -project Quill.xcodeproj -target QuillMac -configuration Debug 2>/dev/null |
  awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER" { print $3 }')
[[ $built == "$DEV_ID" ]] || { echo "Debug builds are $built, not $DEV_ID: refusing to run." >&2; exit 1; }

data="$HOME/Library/Containers/$DEV_ID/Data/Library/Application Support/Quill"
trap 'rm -rf "$data"' EXIT
rm -rf "$data" build/results-mac.xcresult
xcodebuild test -project Quill.xcodeproj -scheme QuillMac -destination platform=macOS \
  -derivedDataPath build/mac-adhoc -resultBundlePath build/results-mac.xcresult \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS="$PWD/scripts/macdev.entitlements" "$@" > build/mac.log 2>&1 || {
    grep -E " error:|Test Case .*failed" build/mac.log | sort -u | cut -c1-200 >&2
    exit 1
  }
grep -E "Test Case .*passed|TEST SUCCEEDED" build/mac.log | sort -u | cut -c1-120
