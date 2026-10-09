#!/usr/bin/env bash
# Proves a compiler zip byte-identical to Flutter's official gen_snapshot on
# every corpus app of one mode (the output of tool/build_corpus.sh).
#
# usage (from the repository root):
#   tool/verify_corpus.sh <compiler zip> <reference dir> <mode> <results dir> [verify args...]
#   [verify args...] are passed to `xcross_gen_snapshot:verify`, e.g.
#   `--manifest manifest.json --flutter 3.47.2`.
# Writes <results dir>/<app>.json for every app and copies the App/app.o of
# every mismatch to <results dir>/mismatch/<app>/. Exits 1 if any app
# differs. Paths are used as given (relative paths keep Git Bash on Windows
# and the Windows Dart VM agreeing on them).
set -uo pipefail

zip=$1
ref=$2
mode=$3
results=$4
shift 4
mkdir -p "$results"
work=.xgs-corpus-verify

checked=0
failed=()
for dir in "$ref"/*/"$mode"; do
  [ -f "$dir/app.dill" ] || continue
  app=$(basename "$(dirname "$dir")")
  checked=$((checked + 1))
  echo "::group::$app ($mode)"
  if dart run xcross_gen_snapshot:verify \
    --compiler-zip "$zip" \
    --dill "$dir/app.dill" \
    --work "$work/$app" \
    --json "$results/$app.json" \
    --expect-json "$dir/official.json" "$@"; then
    echo "::endgroup::"
    echo "byte-identical: $app ($mode)"
  else
    echo "::endgroup::"
    echo "::error::$app ($mode) is NOT byte-identical to the official compiler"
    failed+=("$app")
    mkdir -p "$results/mismatch/$app"
    cp "$work/$app/App" "$work/$app/app.o" "$results/mismatch/$app/" 2>/dev/null || true
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "::error::no corpus apps under $ref/*/$mode"
  exit 1
fi
if [ ${#failed[@]} -gt 0 ]; then
  echo "${#failed[@]} of $checked corpus apps differ: ${failed[*]}"
  exit 1
fi
echo "all $checked corpus apps are byte-identical ($mode)"
