# shellcheck shell=bash
# Shared helpers for scripts/ai/*. Source it; do not run it.
#
# Configuration, in order of precedence:
#   environment variables > .claude/ios.local.env (per checkout, gitignored) > .claude/ios.env (committed)
# Keys: PROJECT or WORKSPACE, SCHEME, APP_BUNDLE_ID, DEVICE_MODEL, IOS_VERSION, TEST_FLAGS,
#       SOURCE_DIRS, BASE_LAUNCH_ARGS (passed on EVERY launch, e.g. a fixture seed or a skip-onboarding
#       flag an app needs before any plain launch), SIM_UDID (local only).

set -euo pipefail

AI_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd))"
AI_DIR="$AI_ROOT/scripts/ai"
BUILD_DIR="$AI_ROOT/.build"
DD="$BUILD_DIR/dd"                      # per-checkout DerivedData: worktrees never share one
EVIDENCE_ROOT="$BUILD_DIR/evidence"
LOCAL_ENV="$AI_ROOT/.claude/ios.local.env"
# Shared, uncommitted state for every worktree of this repo (verify history, the PR digest, cloud
# delegations, healthcheck stamps): inside git's common dir, so `rm -rf .build` never wipes it.
STATE_DIR="$(git -C "$AI_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$AI_ROOT/.git")/ios-ai"
state_dir() { mkdir -p "$STATE_DIR" && echo "$STATE_DIR"; }

die() { echo "ios-ai: $*" >&2; exit 1; }
say() { echo "ios-ai: $*" >&2; }

_load_env() {  # KEY=value lines; ignore comments; never override an exported variable
  local f=$1 line key
  [[ -f $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# || ! $line == *=* ]] && continue
    key=${line%%=*}; key=${key//[[:space:]]/}
    [[ -n ${!key+x} ]] && continue
    export "$key=${line#*=}"
  done < "$f"
}
# The simulator belongs to THIS checkout: never inherit it from a parent process running in
# another checkout (a worktree script, a nested call), which would drive or delete that one's device.
unset SIM_UDID SIM_OWNER
_load_env "$LOCAL_ENV"
_load_env "$AI_ROOT/.claude/ios.env"

: "${DEVICE_MODEL:=iPhone 17 Pro}"
: "${TEST_FLAGS:=}"
: "${SOURCE_DIRS:=.}"
: "${BASE_LAUNCH_ARGS:=}"
[[ -n ${SCHEME:-} ]] || die "SCHEME is not set: run the kit's install.sh, or set it in .claude/ios.env"

# The -project/-workspace pair every xcodebuild call needs.
xc_container() {
  if [[ -n ${WORKSPACE:-} ]]; then echo "-workspace" "$AI_ROOT/$WORKSPACE"
  elif [[ -n ${PROJECT:-} ]]; then echo "-project" "$AI_ROOT/$PROJECT"
  else die "neither PROJECT nor WORKSPACE is set in .claude/ios.env"; fi
}

# The newest available iOS runtime matching IOS_VERSION (or the newest overall).
runtime_id() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
want = sys.argv[1]
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r.get("platform") == "iOS"]
if want:
    rts = [r for r in rts if r["version"] == want or r["version"].startswith(want + ".")]
if not rts:
    sys.exit("no available iOS runtime" + (f" {want}" if want else "") + "; install one in Xcode > Settings > Components")
print(sorted(rts, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])' "${IOS_VERSION:-}"
}

sim_state() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == sys.argv[1]:
            print(d["state"]); sys.exit(0)
print("Missing")' "$1"
}

# This checkout's own simulator. Created on first use and recorded in .claude/ios.local.env,
# so every worktree, including ones Claude Code creates with --worktree, gets its own device
# without a setup step, and no two checkouts ever drive the same simulator.
ensure_sim() {
  # A record copied from another checkout (a worktree include, a cp -R) names that checkout's
  # device: ignore it, so two sessions never share a simulator.
  if [[ -n ${SIM_UDID:-} && -n ${SIM_OWNER:-} && $SIM_OWNER != "$AI_ROOT" ]]; then unset SIM_UDID; fi
  if [[ -n ${SIM_UDID:-} && $(sim_state "$SIM_UDID") != Missing ]]; then
    [[ $(sim_state "$SIM_UDID") == Booted ]] || { xcrun simctl boot "$SIM_UDID" 2>/dev/null || true; }
    xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
    echo "$SIM_UDID"; return
  fi
  local tag name rt udid
  tag=$(printf '%s' "$AI_ROOT" | shasum | cut -c1-6)
  name="ai-$(basename "$AI_ROOT")-$tag"
  rt=$(runtime_id)
  udid=$(xcrun simctl create "$name" "$DEVICE_MODEL" "$rt")
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  # A new simulator lays the keyboard's "slide to type" tip over any focused field.
  xcrun simctl spawn "$udid" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true 2>/dev/null || true
  mkdir -p "$(dirname "$LOCAL_ENV")"
  { grep -vE '^SIM_(UDID|OWNER)=' "$LOCAL_ENV" 2>/dev/null || true; echo "SIM_UDID=$udid"; echo "SIM_OWNER=$AI_ROOT"; } > "$LOCAL_ENV.tmp" && mv "$LOCAL_ENV.tmp" "$LOCAL_ENV"
  export SIM_UDID=$udid SIM_OWNER=$AI_ROOT
  say "created simulator $name ($DEVICE_MODEL, $(basename "$rt")) for this checkout: $udid"
  echo "$udid"
}

# Every file this change touches: modified, staged and untracked, relative to the repo root.
# Another xcodebuild already using this checkout's DerivedData (a background /verify, a test run):
# a second one fails with "database is locked", which reads like a broken build.
dd_busy() { pgrep -f "xcodebuild.*-derivedDataPath $DD( |$)" >/dev/null 2>&1; }
wait_dd() {  # wait for it (up to BUILD_WAIT seconds, default 900) instead of failing
  dd_busy || return 0
  say "another build or test is using this checkout's DerivedData; waiting for it (up to ${BUILD_WAIT:-900}s)"
  local waited=0
  while dd_busy && (( waited < ${BUILD_WAIT:-900} )); do sleep 5; waited=$((waited + 5)); done
  dd_busy && die "still busy after ${waited}s: let it finish (pgrep -fl xcodebuild), or set BUILD_WAIT"
  return 0
}

# Where this branch left the default branch: the scope of "this change" for every gate. On the
# default branch with nothing ahead it is HEAD, so the scope is just the uncommitted work. Without it,
# a branch whose work was already committed (the state before pr.sh, and every PR the lead verifies)
# had its format and reach gates check nothing and pass.
base_commit() {
  local ref; ref=$(git -C "$AI_ROOT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n $ref ]] && git -C "$AI_ROOT" merge-base HEAD "$ref" 2>/dev/null; then return; fi
  echo HEAD
}
changed_files() {  # committed on this branch + uncommitted + untracked, relative to the repo root
  local base; base=$(base_commit)
  { git -C "$AI_ROOT" diff --name-only "$base" 2>/dev/null; git -C "$AI_ROOT" ls-files --others --exclude-standard 2>/dev/null; } | sort -u
}

app_path() {  # the built .app for the simulator, from this checkout's DerivedData
  find "$DD/Build/Products" -maxdepth 2 -name '*.app' -path '*iphonesimulator*' -not -path '*Tests*' -print 2>/dev/null \
    | while read -r a; do [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$a/Info.plist" 2>/dev/null) == "${APP_BUNDLE_ID:-}" ]] && echo "$a"; done | head -1
}
