#!/usr/bin/env bash
# swift-format with the repo's own config (.swift-format), on changed files by default.
# usage: format.sh [--lint] [--all | files…]
source "$(dirname "$0")/lib.sh"
mode=format; [[ ${1:-} == --lint ]] && { mode=lint; shift; }
cd "$AI_ROOT"
files=()
if [[ ${1:-} == --all ]]; then
  for d in $SOURCE_DIRS; do while IFS= read -r f; do files+=("$f"); done < <(find "$d" -name '*.swift' -not -path '*/.build/*' -not -path '*/DerivedData/*' -not -path '*scripts/ai/*'); done
elif (( $# )); then files=("$@")
else while IFS= read -r f; do [[ $f == *.swift && -f $f && $f != scripts/ai/* ]] && files+=("$f"); done < <(changed_files); fi
# (scripts/ai/*.swift is kit tooling, not project code: never held to the project's style.)
(( ${#files[@]} )) || { echo "format: no Swift files to check"; exit 0; }
cfg=(); [[ -f .swift-format ]] && cfg=(--configuration .swift-format)
if [[ $mode == lint ]]; then
  out=$(xcrun swift-format lint --strict ${cfg[@]+"${cfg[@]}"} "${files[@]}" 2>&1) || true
  n=$(printf '%s' "$out" | grep -c 'warning\|error' || true)
  [[ -n $out ]] && printf '%s\n' "$out" | sed "s|$AI_ROOT/||" | head -40
  echo "format: ${#files[@]} file(s) · $n finding(s)"; [[ $n -eq 0 ]]
else
  xcrun swift-format format --in-place ${cfg[@]+"${cfg[@]}"} "${files[@]}"; echo "format: formatted ${#files[@]} file(s)"
fi
