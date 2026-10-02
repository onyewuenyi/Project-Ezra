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
[[ -f $AI_ROOT/.mcp.json ]] && grep -q mcpbridge "$AI_ROOT/.mcp.json" && ok ".mcp.json registers xcrun mcpbridge" || warn ".mcp.json has no Xcode server"
exit $bad
