#!/usr/bin/env bash
# The visual matrix: every screen in .claude/ios-screens.txt (or the names given) captured at
# default, dark and the largest accessibility text size, plus one side-by-side sheet per screen.
# It captures; it cannot judge layout. Someone (the ui-verify agent, or you) must LOOK at each sheet.
# What it CAN check: a line may declare labels the screen must show (expect:) or must not (absent:);
# with Xcode running, those are asserted against the live UI hierarchy (xcui.py, Xcode's device
# interaction). Without Xcode the assertions are reported as skipped, never as passed.
#   empty | -EmptyState | expect: No plants yet | absent: Monstera
# usage: visual.sh [screen names…]
source "$(dirname "$0")/lib.sh"
cd "$AI_ROOT"
screens="$AI_ROOT/.claude/ios-screens.txt"
[[ -f $screens ]] || die "no .claude/ios-screens.txt (lines: name | launch arguments)"
# A screen whose seam the app no longer reads would be captured as the wrong screen: stop first.
python3 "$AI_DIR/screens-drift.py" || die "fix .claude/ios-screens.txt first (/map refresh)"
out="$EVIDENCE_ROOT/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
S() { "$AI_DIR/sim.sh" "$@"; }
S install >/dev/null; S statusbar >/dev/null
fail=0; t0=$(date +%s); xcode_down=""
trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }
while IFS='|' read -r name args f3 f4 || [[ -n $name ]]; do
  name=$(trim "$name")
  [[ -z $name || $name == \#* ]] && continue   # before any parsing: a comment may hold an apostrophe
  args=$(trim "${args:-}")
  expects=(); for f in "${f3:-}" "${f4:-}"; do
    f=$(trim "$f")
    case $f in
      expect:*) IFS=';' read -r -a xs <<< "${f#expect:}"; for x in ${xs[@]+"${xs[@]}"}; do x=$(trim "$x"); [[ -n $x ]] && expects+=(--expect "$x"); done ;;
      absent:*) IFS=';' read -r -a xs <<< "${f#absent:}"; for x in ${xs[@]+"${xs[@]}"}; do x=$(trim "$x"); [[ -n $x ]] && expects+=(--absent "$x"); done ;;
    esac
  done
  if (( $# )) && ! printf '%s\n' "$@" | grep -qx "$name"; then continue; fi
  for v in default dark ax5; do
    case $v in
      default) S appearance light >/dev/null; S size large >/dev/null ;;
      dark) S appearance dark >/dev/null; S size large >/dev/null ;;
      ax5) S appearance light >/dev/null; S size accessibility-extra-extra-extra-large >/dev/null ;;
    esac
    # shellcheck disable=SC2086
    S launch $args >/dev/null; sleep "${VISUAL_WAIT:-4}"
    if ! S alive; then echo "visual: $name/$v: the app is not running after launch"; fail=1; continue; fi
    S shot "$out/$name-$v.png" >/dev/null
  done
  if (( ${#expects[@]} )) && [[ -n $xcode_down ]]; then
    echo "visual: $name: hierarchy assertions SKIPPED (not observed, not passed): $xcode_down"
  elif (( ${#expects[@]} )); then
    container=$AI_ROOT/${WORKSPACE:-$PROJECT}
    set +e
    python3 "$AI_DIR/xcui.py" --udid "$(S udid)" --container "$container" --bundle "$APP_BUNDLE_ID" \
      --args="$args" --name "$name" "${expects[@]}" > "$out/$name-assert.txt" 2>&1
    xr=$?; set -e
    case $xr in
      0) echo "visual: $name: hierarchy assertions passed ($(grep -c '^ok' "$out/$name-assert.txt"))" ;;
      3) xcode_down=$(grep -m1 '^xcui' "$out/$name-assert.txt" | cut -c1-180)
         echo "visual: $name: hierarchy assertions SKIPPED (not observed, not passed): $xcode_down" ;;
      *) echo "visual: $name: hierarchy assertion FAILED:"; grep -E '^FAIL|^xcui' "$out/$name-assert.txt"; fail=1 ;;
    esac
  fi
  S compare "$out/$name.png" "default=$out/$name-default.png" "dark=$out/$name-dark.png" "AX5=$out/$name-ax5.png" >/dev/null 2>&1 \
    && echo "JUDGE $out/$name.png" || echo "visual: $name: comparison sheet failed (individual shots are in $out)"
done < "$screens"
S appearance light >/dev/null; S size large >/dev/null; S statusbar clear >/dev/null || true
crashes=$(S crashes "$t0")
[[ -n $crashes ]] && { echo "visual: crash report(s) during the matrix:"; echo "$crashes"; fail=1; }
echo "visual: evidence in ${out#$AI_ROOT/}"
exit $fail
