#!/usr/bin/env bash
# One run from a fresh Mac (with Xcode) to a working loop: toolchain, Apple's skills, this
# checkout's simulator, and a smoke test (list, build, install, launch, screenshot). Fails loudly.
source "$(dirname "$0")/lib.sh"
cd "$AI_ROOT"
step() { echo; echo "== $*"; }
step "1/4 toolchain"
"$AI_DIR/doctor.sh" || die "fix the FAIL lines above, then re-run"
step "2/4 Apple's Xcode skills -> ~/.claude/skills (per developer, never committed)"
want=$(xcodebuild -version | tail -1)
if [[ $(cat "$HOME/.claude/skills/.xcode-skills-version" 2>/dev/null) != "$want" ]]; then
  mkdir -p "$HOME/.claude/skills"
  xcrun agent skills export --output-dir "$HOME/.claude/skills" --replace-existing | tail -12
  echo "$want" > "$HOME/.claude/skills/.xcode-skills-version"
else echo "already exported for $want"; fi
step "3/4 this checkout's simulator"
echo "simulator: $(ensure_sim)"
step "4/4 smoke test"
read -r -a container <<< "$(xc_container)"
xcodebuild -list "${container[@]}" >/dev/null || die "xcodebuild -list failed"
echo "xcodebuild -list: ok"
"$AI_DIR/build.sh" || die "the build has errors or new warnings (see above; full log in .build/build.log)"
"$AI_DIR/sim.sh" install
"$AI_DIR/sim.sh" guard 4
shot="$EVIDENCE_ROOT/bootstrap.png"; "$AI_DIR/sim.sh" shot "$shot" >/dev/null
[[ -s $shot ]] || die "no screenshot was written"
echo; echo "bootstrap: OK · screenshot ${shot#$AI_ROOT/}"
echo "Optional: Xcode > Settings > Intelligence > Model Context Protocol > Xcode Tools ON, then open the project in Xcode to use previews and device interaction."
