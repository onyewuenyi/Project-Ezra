#!/usr/bin/env bash
# Run tests on this checkout's simulator; print failures and one summary line from the
# .xcresult (never from the log: -quiet hides Swift Testing output entirely).
# usage: test.sh [-only-testing:Target/Suite[/test] …]
source "$(dirname "$0")/lib.sh"
udid=$(ensure_sim)
mkdir -p "$BUILD_DIR"; rm -rf "$BUILD_DIR/tests.xcresult"
read -r -a container <<< "$(xc_container)"
read -r -a extra <<< "$TEST_FLAGS"
set +e
xcodebuild test "${container[@]}" -scheme "$SCHEME" -destination "id=$udid" \
  -derivedDataPath "$DD" -resultBundlePath "$BUILD_DIR/tests.xcresult" ${extra[@]+"${extra[@]}"} "$@" > "$BUILD_DIR/test.log" 2>&1
rc=$?
set -e
cd "$AI_ROOT"
if [[ -d $BUILD_DIR/tests.xcresult ]]; then
  python3 "$AI_DIR/xcresult.py" test "$BUILD_DIR/tests.xcresult" || rc=1
  if grep -q "Restarting after unexpected exit" "$BUILD_DIR/test.log"; then
    echo "tests: note: the test host restarted after an unexpected exit; read .build/test.log before trusting a pass or a fail"
  fi
else
  grep -E "error:|TEST FAILED|BUILD FAILED" "$BUILD_DIR/test.log" | head -20
  echo "tests: failed before a result bundle was written · log: .build/test.log"; rc=1
fi
exit $rc
