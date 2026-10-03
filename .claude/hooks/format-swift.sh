#!/usr/bin/env bash
# PostToolUse: format each edited .swift file with the repo's .swift-format (no config: no-op). Never blocks.
f=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("tool_response") or {}).get("filePath") or (d.get("tool_input") or {}).get("file_path") or "")' 2>/dev/null)
[[ $f == *.swift && -f $f ]] || exit 0
root=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null || dirname "$f")
# Only with the repo's own config: swift-format's defaults (2-space) would restyle a 4-space codebase.
[[ -f $root/.swift-format ]] || exit 0
xcrun swift-format format --in-place --configuration "$root/.swift-format" "$f" >/dev/null 2>&1 || true
exit 0
