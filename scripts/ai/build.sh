#!/usr/bin/env bash
# Build for this checkout's simulator into this checkout's DerivedData (.build/dd).
# Prints only errors, NEW warnings (vs .claude/ios-warnings.txt) and one summary line;
# the full log is kept in .build/build.log.
# usage: build.sh [--update-baseline] [extra xcodebuild args…]
source "$(dirname "$0")/lib.sh"
update=""; [[ ${1:-} == --update-baseline ]] && { update=--update-baseline; shift; }
# First build in a repo with no baseline: today's warnings become the accepted baseline, so an
# existing codebase's backlog is not reported as N "new" warnings; only later additions fail.
first_baseline=0
[[ -f $AI_ROOT/.claude/ios-warnings.txt ]] || { update=--update-baseline; first_baseline=1; }
# A baseline must come from a CLEAN build: an incremental build reports warnings only for the files
# it recompiles, so it would record (almost) nothing and later flag old warnings as new.
action=build; [[ -n $update ]] && { action="clean build"; say "recording the warning baseline from a clean build (one-off, slower)"; }
udid=$(ensure_sim)
mkdir -p "$BUILD_DIR"; rm -rf "$BUILD_DIR/build.xcresult"
read -r -a container <<< "$(xc_container)"
set +e
xcodebuild $action "${container[@]}" -scheme "$SCHEME" -destination "id=$udid" \
  -derivedDataPath "$DD" -resultBundlePath "$BUILD_DIR/build.xcresult" "$@" > "$BUILD_DIR/build.log" 2>&1
rc=$?
set -e
cd "$AI_ROOT"
if [[ -d $BUILD_DIR/build.xcresult ]]; then
  python3 "$AI_DIR/xcresult.py" build "$BUILD_DIR/build.xcresult" --baseline "$AI_ROOT/.claude/ios-warnings.txt" $update || rc=1
  if [[ $first_baseline == 1 && -f $AI_ROOT/.claude/ios-warnings.txt ]]; then
    say "no warning baseline existed: recorded today's $(grep -cv -e '^#' -e '^$' "$AI_ROOT/.claude/ios-warnings.txt" || true) warning(s) in .claude/ios-warnings.txt (commit it; review with your team). Only NEW warnings fail from now on."
  fi
else
  grep -E "error:|BUILD FAILED" "$BUILD_DIR/build.log" | head -20
  echo "build: failed before a result bundle was written · log: .build/build.log"
  rc=1
fi
exit $rc
