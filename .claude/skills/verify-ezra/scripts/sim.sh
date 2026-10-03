#!/usr/bin/env bash
# sim.sh: drive an iOS simulator for verification. One subcommand per verb.
# Every command takes an explicit UDID; resolve one with `pick`, never by name alone.
set -euo pipefail

REG_DIR="${IOS_STACK_HOME:-$HOME/.ios-stack}"; REG="$REG_DIR/simulators.txt"
die() { echo "sim.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

usage() {
  cat <<'EOF'
usage: sim.sh <command> [args]

  pick <device name> <iOS version>      print the UDID matching name AND runtime (e.g. "iPhone 17 Pro" 27.0)
  create <name> <device model> <iOS version>
                                        create, boot and prepare a dedicated simulator; print its UDID and
                                        record it in the registry so `destroy` may later remove it
  destroy <udid>                        shut down and delete a simulator THIS script created (refuses others)
  boot <udid>                           boot and wait until usable
  prepare <udid>                        one-time setup of a NEW simulator: dismiss the keyboard's "slide to type" tip
  doctor <udid> [bundle id]             read-only health check: toolchain, runtime, disk, concurrent builds
  build <udid> <derived dir> -- <xcodebuild args>
                                        build for this simulator into an ISOLATED derived-data dir, print the .app path
  install <udid> <path.app>             install, then verify the installed binary is the one given
  launch <udid> <bundle id> [args...]   terminate any running copy, launch with args, stream console to $SIM_LOG if set
  guard <udid> <bundle id> [seconds]    plain launch, no args: the app must still be alive after N seconds (default 4)
  alive <udid> <bundle id>              exit 0 if the app process is running
  crashes <bundle exec name> <since>    list crash reports newer than <since> (a `date +%s` stamp); some traps
                                        (a SwiftUI SIGTRAP) write none, so pair it with `alive` after the action
  shot <udid> <out.png>                 screenshot
  size <udid> <category>                Dynamic Type: extra-small … extra-extra-extra-large, accessibility-medium … accessibility-extra-extra-extra-large
  appearance <udid> light|dark
  statusbar <udid> [clear]              9:41, full bars, full battery (or clear the override)
  record <udid> <out.mov> <seconds>     screen recording for motion review
  compare <out.png> <a.png> <b.png> [label=path …]
                                        side-by-side comparison, each captioned (file name, or the given label)
  frames <in.mov> <out.png> [fps] [cols]
                                        tile a recording into one contact sheet (default 10 fps, 6 columns)
  openurl <udid> <url>                  deep link through the system, the path a user's tap takes
  privacy <udid> grant|revoke|reset <service> <bundle id>
                                        pre-answer a permission prompt (camera, microphone, photos, location, contacts, …)
  shutdown-all                          shut down every booted simulator (frees a wedged runtime)
EOF
}

udid_state() { xcrun simctl list devices -j | python3 -c '
import json,sys
u=sys.argv[1]
for rt,devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["udid"]==u: print(d["state"]); sys.exit(0)
sys.exit(1)' "$1"; }

cmd=${1:-}; [[ -n "$cmd" ]] || { usage; exit 2; }; shift

case "$cmd" in
pick)
  [[ $# -eq 2 ]] || die "pick <device name> <iOS version>"
  xcrun simctl list devices available -j | python3 -c '
import json,sys
name,ver=sys.argv[1],sys.argv[2]
key="iOS-"+ver.replace(".","-")
hits=[d["udid"] for rt,devs in json.load(sys.stdin)["devices"].items()
      if rt.endswith(key) for d in devs if d["name"]==name and d.get("isAvailable",True)]
if not hits:
    sys.exit(f"no available \"{name}\" on iOS {ver}; see: xcrun simctl list devices available")
if len(hits)>1:
    print(f"warning: {len(hits)} matches, using the first", file=sys.stderr)
print(hits[0])' "$1" "$2"
  ;;

boot)
  u=${1:?udid}
  [[ "$(udid_state "$u")" == "Booted" ]] || xcrun simctl boot "$u"
  xcrun simctl bootstatus "$u" -b >/dev/null
  echo "booted $u"
  ;;

create)
  [[ $# -eq 3 ]] || die "create <name> <device model> <iOS version>"
  rt=$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
v=sys.argv[1]
hits=[r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["platform"]=="iOS" and (r["version"]==v or r["version"].startswith(v+"."))]
if not hits: sys.exit(f"no available iOS {v} runtime; see: xcrun simctl list runtimes")
print(hits[-1])' "$3")
  u=$(xcrun simctl create "$1" "$2" "$rt")
  mkdir -p "$REG_DIR"; echo "$u $1" >> "$REG"
  "$BASH" "$0" boot "$u" >/dev/null && "$BASH" "$0" prepare "$u" >/dev/null
  echo "$u"
  ;;

destroy)
  u=${1:?udid}
  grep -q "^$u " "$REG" 2>/dev/null || die "refusing: $u was not created by sim.sh create (registry: $REG)"
  xcrun simctl shutdown "$u" 2>/dev/null || true
  xcrun simctl delete "$u"
  grep -v "^$u " "$REG" > "$REG.tmp" || true; mv "$REG.tmp" "$REG"
  echo "destroyed $u"
  ;;

prepare)
  u=${1:?udid}
  # A brand-new simulator lays the keyboard's "slide to type" tip over half the screen
  # whenever a field is focused. Per-device preference, so it touches no other simulator.
  xcrun simctl spawn "$u" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true
  echo "prepared $u (keyboard tip dismissed; relaunch the app for it to apply)"
  ;;

doctor)
  u=${1:?udid}; bid=${2:-}; bad=0
  ok() { echo "  ok    $*"; }; warn() { echo "  WARN  $*"; }; fail() { echo "  FAIL  $*"; bad=1; }
  echo "doctor $u"
  if xv=$(xcodebuild -version 2>/dev/null); then ok "${xv%%$'\n'*} ($(xcode-select -p))"; else fail "xcodebuild not runnable"; fi
  st=$(udid_state "$u" 2>/dev/null) || { fail "no simulator with UDID $u"; exit 1; }
  rt=$(xcrun simctl list devices -j | python3 -c '
import json,sys
for rt,devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["udid"]==sys.argv[1]: print(rt.rsplit(".",1)[-1], d["name"])' "$u")
  ok "device: $rt, $st"
  if [[ "$st" == "Booted" ]]; then
    # A runtime whose dyld cannot load libSystem fails every process, and reads exactly like an app crash.
    # Name the tool, not a path: absolute paths resolve against the host, not the runtime root.
    if xcrun simctl spawn "$u" launchctl list >/dev/null 2>&1; then ok "runtime spawns processes"
    else fail "runtime cannot spawn a process: run 'sim.sh shutdown-all' then boot again before measuring anything"; fi
  else warn "not booted (sim.sh boot $u)"; fi
  free=$(df -g "$HOME" | awk 'NR==2{print $4}')
  (( free >= 10 )) && ok "disk: ${free}G free" || warn "disk: ${free}G free (simulator installs fail oddly under ~10G)"
  n=$( (pgrep -f 'xcodebuild .*(build|test|archive)' || true) | wc -l | tr -d ' ')
  (( n == 0 )) && ok "no other xcodebuild running" || warn "$n other xcodebuild process(es): a shared DerivedData can be overwritten under you, use an isolated -derivedDataPath"
  booted=$( (xcrun simctl list devices booted | grep -c Booted) || true)
  (( booted <= 1 )) || warn "$booted simulators booted: another session may be driving one, pick yours by UDID"
  if [[ -n "$bid" && "$st" == "Booted" ]]; then
    if c=$(xcrun simctl get_app_container "$u" "$bid" 2>/dev/null); then
      ok "installed: $bid ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$c"))"
    else warn "$bid not installed"; fi
  fi
  exit $bad
  ;;

build)
  u=${1:?udid}; dd=${2:?derived data dir}; shift 2
  [[ "${1:-}" == "--" ]] && shift
  log="$dd/build.log"; mkdir -p "$dd"
  if ! xcodebuild "$@" -destination "id=$u" -derivedDataPath "$dd" -configuration Debug build >"$log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$log" | head -40 >&2; die "build failed, full log: $log"
  fi
  app=$(find "$dd/Build/Products" -maxdepth 2 -name '*.app' -path '*iphonesimulator*' -print -quit)
  [[ -n "$app" ]] || die "build succeeded but no .app under $dd/Build/Products"
  echo "$app"
  ;;

install)
  u=${1:?udid}; app=${2:?path.app}
  [[ -d "$app" ]] || die "no such app: $app"
  bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
  exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
  xcrun simctl install "$u" "$app"
  inst=$(xcrun simctl get_app_container "$u" "$bid" app)
  # Two sessions sharing a build dir or a simulator silently install a binary that isn't yours.
  if cmp -s "$app/$exe" "$inst/$exe"; then echo "installed $bid (binary verified)"
  else die "installed binary differs from $app: another build or session replaced it"; fi
  ;;

launch)
  u=${1:?udid}; bid=${2:?bundle id}; shift 2
  if [[ -n "${SIM_LOG:-}" ]]; then
    xcrun simctl launch --terminate-running-process --console-pty "$u" "$bid" "$@" >"$SIM_LOG" 2>&1 &
    sleep 1; echo "launched $bid, console -> $SIM_LOG (pid $!)"
  else
    xcrun simctl launch --terminate-running-process "$u" "$bid" "$@"
  fi
  ;;

alive)
  u=${1:?udid}; bid=${2:?bundle id}
  # Capture first: `grep -q` closes the pipe early and pipefail would report a match as a failure.
  procs=$(xcrun simctl spawn "$u" launchctl list 2>/dev/null) || exit 1
  [[ "$procs" == *"UIKitApplication:$bid["* ]]
  ;;

guard)
  u=${1:?udid}; bid=${2:?bundle id}; secs=${3:-4}
  xcrun simctl launch --terminate-running-process "$u" "$bid" >/dev/null
  sleep "$secs"
  if "$BASH" "$0" alive "$u" "$bid"; then echo "guard ok: plain launch alive after ${secs}s"
  else die "guard FAILED: a plain launch died. The runtime or the build is broken; nothing measured now is about your change"; fi
  ;;

crashes)
  exe=${1:?executable name}; since=${2:?epoch seconds}
  # BSD find has no -newermt @epoch (it errored silently, so "no crashes" was never a real answer).
  python3 - "$HOME/Library/Logs/DiagnosticReports" "$exe" "$since" <<'PY'
import sys, pathlib, time
d, exe, since = pathlib.Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
for p in sorted(d.glob(f"{exe}*.ips")) if d.exists() else []:
    if p.stat().st_mtime >= since:
        print(time.strftime("%H:%M:%S", time.localtime(p.stat().st_mtime)), "", p)
PY
  ;;

shot)
  u=${1:?udid}; out=${2:?out.png}; mkdir -p "$(dirname "$out")"
  xcrun simctl io "$u" screenshot "$out" >/dev/null 2>&1 && echo "$out"
  ;;

size)
  u=${1:?udid}; xcrun simctl ui "$u" content_size "${2:?category}"; echo "content size: $2"
  ;;

appearance)
  u=${1:?udid}; xcrun simctl ui "$u" appearance "${2:?light|dark}"; echo "appearance: $2"
  ;;

statusbar)
  u=${1:?udid}
  if [[ "${2:-}" == "clear" ]]; then xcrun simctl status_bar "$u" clear
  else xcrun simctl status_bar "$u" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
         --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100; fi
  ;;

record)
  u=${1:?udid}; out=${2:?out.mov}; secs=${3:?seconds}; mkdir -p "$(dirname "$out")"
  xcrun simctl io "$u" recordVideo --codec=h264 --force "$out" >/dev/null 2>&1 &
  rp=$!; sleep "$secs"; kill -INT "$rp"; wait "$rp" 2>/dev/null || true
  echo "$out"
  ;;

compare)
  # AppKit via the Swift interpreter: always present with Xcode, unlike an ffmpeg built with drawtext.
  out=${1:?out.png}; shift; (( $# >= 2 )) || die "compare <out.png> <a.png> <b.png> [label=path …]"
  cs="$(dirname "$0")/compare.swift"
  [[ -f "$cs" ]] || die "compare.swift must sit beside sim.sh (copy it from the ios-stack plugin's scripts/)"
  swift "$cs" "$out" "$@"
  ;;

frames)
  need ffmpeg
  in=${1:?in.mov}; out=${2:?out.png}; fps=${3:-10}; cols=${4:-6}
  n=$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 "$in")
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
  total=$(python3 -c "import math;print(max(1,math.ceil(float('$dur')*$fps)))")
  rows=$(( (total + cols - 1) / cols ))
  ffmpeg -v error -y -i "$in" -vf "fps=$fps,scale=300:-1,drawtext=text='%{n}':x=8:y=8:fontsize=28:fontcolor=yellow:box=1:boxcolor=black@0.6,tile=${cols}x${rows}" -frames:v 1 "$out" 2>/dev/null \
    || ffmpeg -v error -y -i "$in" -vf "fps=$fps,scale=300:-1,tile=${cols}x${rows}" -frames:v 1 "$out"
  echo "$out ($total frames at ${fps}fps from $n source frames, ${cols}x${rows})"
  ;;

openurl)
  xcrun simctl openurl "${1:?udid}" "${2:?url}"
  ;;

privacy)
  xcrun simctl privacy "${1:?udid}" "${2:?grant|revoke|reset}" "${3:?service}" "${4:?bundle id}"
  ;;

shutdown-all)
  xcrun simctl shutdown all; echo "all simulators shut down"
  ;;

-h|--help|help) usage ;;
*) usage; exit 2 ;;
esac
