#!/bin/zsh
# Run the on-device model evals and pull their reports — the sequence Monday's GA
# decision runs on, as one command.
#
#   scripts/device-evals.sh [dup|fm|all]        (default: all)
#
# Needs the phone ON, UNLOCKED, and — for the length of the run — NOT auto-locking:
# Settings ▸ Display & Brightness ▸ Auto-Lock ▸ Never. Every step but the build needs
# an unlocked device, and a locked one fails with install error 14 / launch
# FBSOpenApplicationService error 1, which is what twelve retries produced on
# 2026-09-12. Each harness prints a heartbeat per judgment, so a stalled `judged`
# count means the phone locked mid-run; a moving one means wait.
#
# Reports land beside this script's output dir as <name>-device.txt with the run
# stamp on line 3 — quote no number without it.

set -u
DEV="${EZRA_DEVICE:-8F619261-7B00-53B2-AC1E-77ECB892571B}"   # Charles's iPhone 15 Pro Max
BUNDLE=amanze-studios.Project-Ezra
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${EZRA_EVAL_OUT:-$ROOT/eval-reports}"
mkdir -p "$OUTDIR"
WHICH="${1:-all}"

echo "▸ building for device"
xcodebuild -project "$ROOT/Project-Ezra.xcodeproj" -scheme Project-Ezra \
  -destination "id=$DEV" -configuration Debug -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD" | tail -3
APP=$(find ~/Library/Developer/Xcode/DerivedData/Project-Ezra-*/Build/Products/Debug-iphoneos \
  -maxdepth 1 -name "Project-Ezra.app" -print0 2>/dev/null | xargs -0 ls -td | head -1)
[[ -z "$APP" ]] && { echo "no device build product found"; exit 1; }

echo "▸ installing $APP"
until xcrun devicectl device install app --device "$DEV" "$APP" 2>&1 | grep -q "App installed"; do
  echo "  install failed — is the phone unlocked? retrying in 15s"; sleep 15
done

run_eval() {
  local flag="$1" file="$2" marker="$3" name="$4"
  echo "▸ launching $flag"
  until xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE" -- "$flag" -EvalToFile 2>&1 | grep -q "Launched"; do
    echo "  launch failed — is the phone unlocked? retrying in 15s"; sleep 15
  done
  local out="$OUTDIR/$name-device.txt" last=-1 stalled=0
  while true; do
    sleep 10
    xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source "Documents/$file" --destination "$out" >/dev/null 2>&1
    if grep -q "$marker" "$out" 2>/dev/null; then break; fi
    local n; n=$(grep -cE "^  (… )?[0-9]+/[0-9]+" "$out" 2>/dev/null || echo 0)
    if [[ "$n" == "$last" ]]; then stalled=$((stalled+1)); else stalled=0; fi
    last=$n
    echo "  $name: $n judged"
    if (( stalled >= 12 )); then echo "  no progress for 2 minutes — the phone probably locked. Unlock it; polling continues."; stalled=0; fi
  done
  echo "▸ $name report → $out"
  sed -n '/── verdict/,$p' "$out"
}

case "$WHICH" in
  dup|all) run_eval -DuplicateSweepEval dupsweep-report.txt "END DUPLICATE SWEEP EVAL" dupsweep ;;
esac
case "$WHICH" in
  fm|all)  run_eval -FMPrimitives fmprimitives-report.txt "END FM PRIMITIVES" fmprimitives ;;
esac
