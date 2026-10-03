#!/usr/bin/env bash
# The release gate: audit what you would SHIP, not the Debug app you tested.
# Without arguments, builds the Release configuration for the simulator (no signing needed) and
# audits it: export compliance, launch screen, iPad orientations, icon, privacy manifests and
# required-reason APIs, usage strings for linked capabilities, debug residue, and launch-argument
# seams outside #if DEBUG. Pass an .xcarchive or .ipa to audit a real archive (signing, entitlements).
# usage: release.sh [path/to/App.xcarchive | App.ipa]
source "$(dirname "$0")/lib.sh"
cd "$AI_ROOT"
if [[ -n ${1:-} ]]; then
  target=$1
else
  read -r -a container <<< "$(xc_container)"
  rdd="$BUILD_DIR/release-dd"; mkdir -p "$BUILD_DIR"
  say "building the Release configuration for the simulator (unsigned) into .build/release-dd"
  xcodebuild build "${container[@]}" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$rdd" CODE_SIGNING_ALLOWED=NO \
    > "$BUILD_DIR/release.log" 2>&1 || { grep -E "error:" "$BUILD_DIR/release.log" | head -20; die "the Release build failed (log: .build/release.log)"; }
  target=$(find "$rdd/Build/Products" -maxdepth 2 -name '*.app' -path '*Release-iphonesimulator*' | while read -r a; do
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$a/Info.plist" 2>/dev/null) == "$APP_BUNDLE_ID" ]] && echo "$a"; done | head -1)
  [[ -n $target ]] || die "no Release .app for $APP_BUNDLE_ID"
fi
# shellcheck disable=SC2086
python3 "$AI_DIR/audit-bundle.py" "$target" --src ${SOURCE_DIRS%% *}
