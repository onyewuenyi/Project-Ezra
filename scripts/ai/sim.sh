#!/usr/bin/env bash
# Drive THIS checkout's simulator (always by UDID, never `booted`, never a bare name).
# usage: sim.sh <command> [args]
#   udid                         print (creating if needed) this checkout's simulator
#   install                      install the built app, verifying the installed binary is ours
#   launch [app args…]           terminate and relaunch with arguments (DEBUG launch arguments)
#   guard [seconds]              plain launch (BASE_LAUNCH_ARGS only) must stay alive, or the environment is broken
#   alive                        exit 0 if the app is running
#   shot <out.png>               screenshot
#   size <category>              Dynamic Type (large, accessibility-extra-extra-extra-large, …)
#   appearance light|dark        appearance
#   statusbar [clear]            9:41, full bars, full battery
#   record <out.mov> <seconds>   screen recording
#   frames <in.mov> <out.png> [fps] [cols]   contact sheet of a recording (AVFoundation)
#   compare <out.png> <label=a.png> <label=b.png> …   labelled side-by-side
#   openurl <url>                deep link the way a tap would
#   crashes <since-epoch>        this app's crash reports since a time (some traps write none: also run `alive`)
#   reset-app                    uninstall the app (fresh-install state for onboarding/seeding)
#   destroy                      delete this checkout's simulator (on worktree removal)
source "$(dirname "$0")/lib.sh"
cmd=${1:-}; shift || true
u() { ensure_sim; }
case "$cmd" in
udid) u ;;
install)
  udid=$(u); app=$(app_path); [[ -n $app ]] || die "no built app for $APP_BUNDLE_ID under .build/dd: run scripts/ai/build.sh"
  exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
  xcrun simctl install "$udid" "$app"
  inst=$(xcrun simctl get_app_container "$udid" "$APP_BUNDLE_ID" app)
  cmp -s "$app/$exe" "$inst/$exe" || die "the installed binary is not the one just built (another build or session replaced it)"
  echo "installed $APP_BUNDLE_ID on $udid (binary verified)" ;;
launch)
  udid=$(u); read -r -a base <<< "$BASE_LAUNCH_ARGS"
  xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" ${base[@]+"${base[@]}"} "$@" >/dev/null
  echo "launched $APP_BUNDLE_ID $BASE_LAUNCH_ARGS $*" ;;
alive)
  udid=$(u); procs=$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null) || exit 1
  [[ $procs == *"UIKitApplication:$APP_BUNDLE_ID["* ]] ;;
guard)
  udid=$(u); read -r -a base <<< "$BASE_LAUNCH_ARGS"
  xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" ${base[@]+"${base[@]}"} >/dev/null; sleep "${1:-4}"
  if "$BASH" "$0" alive; then echo "guard ok: a plain launch is alive after ${1:-4}s"
  else die "guard FAILED: a plain launch died. The simulator runtime or the build is broken; nothing measured now is about your change. Try: xcrun simctl shutdown $udid && xcrun simctl boot $udid"; fi ;;
shot) udid=$(u); mkdir -p "$(dirname "$1")"
  xcrun simctl io "$udid" screenshot "$1" >/dev/null 2>&1 || die "screenshot failed on $udid: is it booted? (xcrun simctl bootstatus $udid; sim.sh guard)"
  echo "$1" ;;
size) xcrun simctl ui "$(u)" content_size "$1"; echo "content size: $1" ;;
appearance) xcrun simctl ui "$(u)" appearance "$1"; echo "appearance: $1" ;;
statusbar)
  udid=$(u)
  if [[ ${1:-} == clear ]]; then xcrun simctl status_bar "$udid" clear
  else xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
         --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100; fi ;;
record)
  udid=$(u); mkdir -p "$(dirname "$1")"
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$1" >/dev/null 2>&1 & rp=$!
  sleep "$2"; kill -INT "$rp"; wait "$rp" 2>/dev/null || true; echo "$1" ;;
frames) swift "$AI_DIR/frames.swift" "$@" ;;
compare) out=$1; shift; swift "$AI_DIR/compare.swift" "$out" "$@" ;;
openurl) xcrun simctl openurl "$(u)" "$1" ;;
crashes)
  exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$(app_path)/Info.plist" 2>/dev/null || echo "$SCHEME")
  # BSD find has no -newermt @epoch: filter by mtime in python (and never fail the caller).
  python3 - "$HOME/Library/Logs/DiagnosticReports" "$exe" "${1:?since-epoch}" <<'PY'
import sys, pathlib
d, exe, since = pathlib.Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
for p in sorted(d.glob(f"{exe}*.ips")) if d.exists() else []:
    if p.stat().st_mtime >= since:
        print(p)
PY
  ;;
reset-app) xcrun simctl uninstall "$(u)" "$APP_BUNDLE_ID" 2>/dev/null || true; echo "uninstalled $APP_BUNDLE_ID" ;;
destroy)
  [[ -n ${SIM_UDID:-} ]] || { echo "no simulator recorded for this checkout"; exit 0; }
  [[ -z ${SIM_OWNER:-} || $SIM_OWNER == "$AI_ROOT" ]] || die "refusing: $SIM_UDID belongs to $SIM_OWNER, not this checkout ($AI_ROOT)"
  xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true; xcrun simctl delete "$SIM_UDID" 2>/dev/null || true
  grep -v '^SIM_UDID=' "$LOCAL_ENV" > "$LOCAL_ENV.tmp" 2>/dev/null || true; mv "$LOCAL_ENV.tmp" "$LOCAL_ENV"
  echo "deleted simulator $SIM_UDID" ;;
*) sed -n '2,19p' "$0"; exit 2 ;;
esac
