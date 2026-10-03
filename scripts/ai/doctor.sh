#!/usr/bin/env bash
# Is this machine and checkout fit to build and verify? Read-only. Run first whenever anything looks off:
# a broken simulator runtime or a stale toolchain looks exactly like an app bug.
source "$(dirname "$0")/lib.sh"
bad=0; ok() { echo "  ok    $*"; }; warn() { echo "  WARN  $*"; }; fail() { echo "  FAIL  $*"; bad=1; }
echo "doctor: $(basename "$AI_ROOT") · scheme $SCHEME"
if v=$(xcodebuild -version 2>/dev/null); then
  major=$(echo "$v" | head -1 | sed -E 's/Xcode ([0-9]+).*/\1/')
  [[ $major -ge ${MIN_XCODE:-27} ]] && ok "${v%%$'\n'*} at $(xcode-select -p)" \
    || fail "${v%%$'\n'*} is older than Xcode ${MIN_XCODE:-27}: sudo xcode-select -s /Applications/Xcode.app"
else fail "xcodebuild not runnable: install Xcode, then sudo xcode-select -s /Applications/Xcode.app"; fi
xcrun swift-format --version >/dev/null 2>&1 && ok "swift-format $(xcrun swift-format --version 2>/dev/null)" || fail "xcrun swift-format missing"
rt=$(runtime_id 2>&1) && ok "iOS runtime $(basename "$rt")" || fail "$rt"
if [[ -n ${SIM_UDID:-} ]]; then
  st=$(sim_state "$SIM_UDID")
  if [[ $st == Missing ]]; then warn "recorded simulator $SIM_UDID is gone; the next build creates a new one"
  elif [[ $st == Booted ]]; then
    xcrun simctl spawn "$SIM_UDID" launchctl list >/dev/null 2>&1 && ok "this checkout's simulator $SIM_UDID is booted and healthy" \
      || fail "simulator $SIM_UDID cannot spawn processes: xcrun simctl shutdown $SIM_UDID && xcrun simctl boot $SIM_UDID"
  else ok "this checkout's simulator $SIM_UDID ($st)"; fi
else ok "no simulator yet; the first build creates one for this checkout"; fi
n=$( (pgrep -fl "xcodebuild" || true) | grep -c -- "$DD" || true)
(( n == 0 )) && ok "no other build using this checkout's DerivedData" || warn "$n xcodebuild process(es) already using $DD"
free=$(df -g "$AI_ROOT" | awk 'NR==2{print $4}'); (( free >= 15 )) && ok "disk: ${free}G free" || warn "disk: ${free}G free (simulators and DerivedData need room)"
if [[ -d $HOME/.claude/skills/swiftui-specialist ]]; then
  want=$(xcodebuild -version 2>/dev/null | tail -1); have=$(cat "$HOME/.claude/skills/.xcode-skills-version" 2>/dev/null || echo "?")
  [[ $want == "$have" ]] && ok "Apple's Xcode skills exported ($have)" || warn "Apple's skills were exported from '$have', Xcode is '$want': scripts/ai/bootstrap.sh re-exports"
else warn "Apple's Xcode skills not exported: scripts/ai/bootstrap.sh"; fi
if pgrep -xq Xcode; then ok "Xcode is running (the Xcode MCP tools can connect)"; else warn "Xcode is not running: the MCP path (previews, device interaction) is off; every step still works from the shell"; fi
trusted=$(AI_ROOT="$AI_ROOT" python3 -c '
import json, os, pathlib
try:
    projects = json.load(open(os.path.expanduser("~/.claude.json"))).get("projects", {})
except Exception:
    print("?"); raise SystemExit
p = pathlib.Path(os.environ["AI_ROOT"]).resolve()
print("yes" if any(projects.get(str(q), {}).get("hasTrustDialogAccepted") for q in [p, *p.parents]) else "no")' 2>/dev/null)
case $trusted in
  yes) ok "Claude Code trusts this folder (its committed permissions and hooks apply)" ;;
  no) warn "Claude Code has not been trusted here: run 'claude' in this folder once and choose Yes, or the committed permission rules are ignored" ;;
esac
if ! command -v gh >/dev/null; then warn "GitHub CLI missing: brew install gh && gh auth login (scripts/ai/pr.sh and protect-main.sh need it)"
elif ! gh auth status >/dev/null 2>&1; then warn "GitHub CLI is not signed in: gh auth login"; fi
if command -v gh >/dev/null && b=$(cd "$AI_ROOT" && gh repo view --json nameWithOwner,defaultBranchRef -q '.nameWithOwner + " " + .defaultBranchRef.name' 2>/dev/null); then
  rules=$(gh api "repos/${b% *}/rules/branches/${b#* }" -q '[.[].type] | join(",")' 2>/dev/null || echo "?")
  if [[ $rules == *non_fast_forward* && $rules == *deletion* && $rules == *pull_request* ]]; then ok "GitHub: '${b#* }' takes changes only through pull requests, no force push or deletion"
  elif [[ $rules == *non_fast_forward* ]]; then warn "GitHub: '${b#* }' still accepts direct pushes: scripts/ai/protect-main.sh"
  else warn "GitHub: '${b#* }' is not protected (force push, deletion, direct push): scripts/ai/protect-main.sh"; fi
fi
[[ -f $AI_ROOT/.mcp.json ]] && grep -q mcpbridge "$AI_ROOT/.mcp.json" && ok ".mcp.json registers xcrun mcpbridge" || warn ".mcp.json has no Xcode server"
exit $bad
