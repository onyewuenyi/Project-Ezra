#!/usr/bin/env bash
# The FAST gate the Stop hook runs: format lint + incremental build, on this change only.
# Skips (exit 0) when no Swift or project file changed, and when this exact change already
# passed (content hash cached in .build/check.pass). Tests are the full gate's job (verify.sh),
# unless CHECK_TESTS=1.
source "$(dirname "$0")/lib.sh"
cd "$AI_ROOT"
relevant=$(changed_files | grep -E '\.(swift|xcdatamodel|plist|xcstrings|entitlements)$|\.xcdatamodel/|project\.pbxproj$' || true)
[[ -n $relevant ]] || { echo "check: no code changes"; exit 0; }
# A build or test already running here reports its own result; a second build would only fail on
# the locked build database and block the turn for nothing.
if dd_busy; then echo "check: skipped, a build or test is already running in this checkout and will report its own result"; exit 0; fi
hash=$( (printf '%s\n' "$relevant"; printf '%s\n' "$relevant" | while IFS= read -r f; do [[ -f $f ]] && shasum "$f"; done) | shasum | cut -c1-16)
[[ -f $BUILD_DIR/check.pass && $(cat "$BUILD_DIR/check.pass") == "$hash" ]] && { echo "check: this exact change already passed"; exit 0; }
swift=$(printf '%s\n' "$relevant" | grep '\.swift$' | grep -v '^scripts/ai/' | while IFS= read -r f; do [[ -f $f ]] && echo "$f"; done || true)
rc=0
if [[ -n $swift ]]; then
  # shellcheck disable=SC2086
  "$AI_DIR/format.sh" --lint $swift || rc=1
fi
"$AI_DIR/build.sh" || rc=1
if [[ ${CHECK_TESTS:-0} == 1 && $rc == 0 ]]; then "$AI_DIR/test.sh" || rc=1; fi
mkdir -p "$BUILD_DIR"
if [[ $rc == 0 ]]; then echo "$hash" > "$BUILD_DIR/check.pass"; echo "check: passed"; else rm -f "$BUILD_DIR/check.pass"; echo "check: FAILED"; fi
exit $rc
