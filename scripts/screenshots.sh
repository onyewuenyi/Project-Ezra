#!/bin/bash
#
# The App Store screenshot set, generated from the verification seams.
#
# **Why generate them (2026-09-20).** App Store Connect requires screenshots at the 6.9"
# iPhone size, and — because this app ships to iPad (`TARGETED_DEVICE_FAMILY = 1,2`) — at
# the 13" iPad size as well. Hand-collecting them means driving the app by thumb twice,
# on two devices, in the same order, from the same data, and doing it again every time a
# surface changes. This repo already has a launch seam for every screen precisely so a
# surface can be reached without a tap; the screenshot set is that machinery pointed at
# the listing.
#
# Everything here runs from ONE seeded store (`-SeedFlowFixtures`), so the same tasks
# appear on every shot and the set reads as one product rather than six unrelated states.
#
# Usage:
#   scripts/screenshots.sh                 # both required sizes
#   scripts/screenshots.sh iphone          # just the 6.9"
#   scripts/screenshots.sh ipad
#
# Output: build/screenshots/<device>/NN-<name>.png
#
set -euo pipefail
cd "$(dirname "$0")/.."

BID=amanze-studios.Project-Ezra
OUT="$PWD/build/screenshots"
WHICH="${1:-all}"

# The 6.9" iPhone and the 13" iPad are the two sizes App Store Connect actually asks for;
# every smaller size is derived from them by Apple.
OS="27.0"
IPHONE_NAME="iPhone 17 Pro Max"
IPAD_NAME="iPad Pro 13-inch (M5)"

# Each entry is: name|launch arguments. `-SeedFlowFixtures` is on every one of them so
# the store is identical shot to shot. The order is the order of the story: what the
# product is, then what it does with what you say, then the judgment it adds.
# The typed canvas was here and is not any more: a keyboard eats half the frame, and
# the canvas is the escape hatch rather than the thing the product is. The orb and the
# reveal are the two beats worth a slot.
# name|seconds to wait before the shot|launch arguments.
#
# The wait is per shot because the states settle at wildly different speeds: a seeded
# list is up in a second, and the reveal has to wait for a real model to finish reading
# the sentence. Seven seconds everywhere caught the reveal mid-thought and produced a
# second picture of the orb — pretty, and not what that slot is for.
SHOTS=(
  "01-tasks|6|-SeedFlowFixtures"
  "02-listening|7|-SeedFlowFixtures -OpenCapture -HoldListening -DriveListeningLevel"
  # The sentence matters. An earlier one ("…, and daycare forms are due friday") is a
  # shape the deterministic read gets WRONG — it returns one task with the other two
  # outcomes stuffed into a wait chip — and a store screenshot must not advertise a
  # wrong read. It is now an eval case (`RambleEvalSet`) instead of a picture. This one
  # reads correctly AND shows the thing the product is distinctive for: "Book flights"
  # comes back waiting on "Renew my passport", which nobody typed.
  "03-reveal|30|-SeedFlowFixtures -OpenCapture \"renew my passport, book flights after it comes through, call mom back\""
  "04-detail|10|-SeedFlowFixtures -OpenTaskDetail 0"
  "05-ask|12|-SeedFlowFixtures -AskHousehold \"what deserves me today?\""
  # NOT Settings, though its "What leaves this device" card is the best argument the
  # product has. The screen opens on the profile, which renders the real name on the
  # machine taking the shot, above a reset receipt from whenever the fixtures were last
  # touched. A store asset must carry neither. Activity makes the same point a different
  # way — every AI act is on the record and reversible — and has no profile card.
  "06-activity|8|-SeedFlowFixtures -OpenActivity"
)

build_once() {
  echo "Building…" >&2
  xcodebuild -project Project-Ezra.xcodeproj -scheme Project-Ezra \
    -destination "platform=iOS Simulator,name=$IPHONE_NAME,OS=$OS" \
    -configuration Debug build 2>&1 | grep -E "error:|BUILD" | tail -2 >&2
  # The DESTINATION matters here: without it these settings describe a DEVICE build,
  # and installing an iphoneos bundle on a simulator fails with a message about the
  # iOS version that sends you looking in entirely the wrong place.
  xcodebuild -project Project-Ezra.xcodeproj -scheme Project-Ezra \
    -destination "platform=iOS Simulator,name=$IPHONE_NAME,OS=$OS" \
    -showBuildSettings -configuration Debug 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{gsub(/^ +| +$/,"",$2); d=$2} / FULL_PRODUCT_NAME /{gsub(/^ +| +$/,"",$2); n=$2} END{print d"/"n}'
}

# A simulator of this name ON THIS RUNTIME. The machine carries several runtimes and
# the same device name exists under each, so a plain name match picked an iOS 26.3
# iPhone 17 Pro Max and the install failed on the deployment target.
udid_for() {
  xcrun simctl list devices available \
    | awk -v want="$1" -v os="-- iOS $OS --" '
        /^-- /{ inblock = ($0 == os); next }
        inblock && index($0, want " (") { if (match($0, /[0-9A-F-]{36}/)) { print substr($0, RSTART, RLENGTH); exit } }'
}

shoot() {
  local label="$1" name="$2"
  local udid
  udid=$(udid_for "$name")
  [[ -n "$udid" ]] || { echo "No iOS $OS simulator named '$name' — skipping $label."; return; }

  # Clear THIS label only. `rm -rf "$OUT"` at the top would be simpler and was wrong:
  # running one size deleted the other size's set, so `screenshots.sh ipad` silently
  # threw away the iPhone shots taken a minute earlier.
  rm -rf "$OUT/$label"
  mkdir -p "$OUT/$label"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  # A clean store, then the app, so a previous run's data cannot leak into the set.
  xcrun simctl uninstall "$udid" "$BID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP" >/dev/null
  # The status bar is part of the picture: a real clock and a full battery, so the set
  # does not advertise that it was taken at 3% on a Tuesday.
  xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 >/dev/null 2>&1 || true

  for entry in "${SHOTS[@]}"; do
    local shot="${entry%%|*}" rest="${entry#*|}"
    local wait="${rest%%|*}" args="${rest#*|}"
    xcrun simctl terminate "$udid" "$BID" >/dev/null 2>&1 || true
    eval "xcrun simctl launch \"$udid\" \"$BID\" $args" >/dev/null 2>&1 || true
    sleep "$wait"
    xcrun simctl io "$udid" screenshot "$OUT/$label/$shot.png" >/dev/null 2>&1
    echo "  $label/$shot.png"
  done
  xcrun simctl terminate "$udid" "$BID" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
}

APP=$(build_once)
[[ -d "$APP" ]] || { echo "Could not locate the built app at '$APP'." >&2; exit 1; }
echo "App: $APP"

[[ "$WHICH" == "all" || "$WHICH" == "iphone" ]] && shoot "iphone-6.9" "$IPHONE_NAME"
[[ "$WHICH" == "all" || "$WHICH" == "ipad" ]] && shoot "ipad-13" "$IPAD_NAME"

echo
echo "Screenshots in $OUT"
echo "Look at every one before uploading: a seam lands on a state, it does not"
echo "guarantee the state is worth showing."
