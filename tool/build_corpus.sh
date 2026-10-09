#!/usr/bin/env bash
# Builds the corpus apps (docs/CORPUS.md) with the official toolchain:
# `flutter build ios --release|--profile --no-codesign -v` for each app, then
# recompiles the app.dill flutter produced with Flutter's own gen_snapshot
# (taken, with its exact flags, from the build log) under fixed output names.
#
# usage: tool/build_corpus.sh <work dir> <out dir> [app...]
#   <work dir>  where the apps are created (`<work dir>/<app>`)
#   <out dir>   receives <app>/<mode>/{app.dill,official.json,build.log}
#   [app...]    default: every corpus app
# Needs `flutter` (the version under test) and `dart` on PATH; run from
# anywhere.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mkdir -p "$1" && cd "$1" && pwd)
out=$(mkdir -p "$2" && cd "$2" && pwd)
shift 2
apps=("$@")
[ ${#apps[@]} -gt 0 ] || apps=(ref_app api_samples stress pub_heavy)
flutter_root=$(cd "$(dirname "$(command -v flutter)")/.." && pwd)

for app in "${apps[@]}"; do
  echo "::group::create $app"
  dir="$work/$app"
  rm -rf "${dir:?}"
  # The project name is the directory name (it is part of the kernel).
  (cd "$work" && flutter create --no-pub "$app")
  case "$app" in
    ref_app)
      # The default `flutter create` app the release manifests name.
      ;;
    api_samples)
      (cd "$repo" && dart run xcross_gen_snapshot:corpus \
        --samples-app "$dir" --flutter-root "$flutter_root")
      (cd "$dir" && flutter pub add collection vector_math)
      ;;
    *)
      [ -d "$repo/corpus/$app" ] || { echo "unknown corpus app $app" >&2; exit 64; }
      rm -rf "${dir:?}/lib" "${dir:?}/test"
      cp -R "$repo/corpus/$app/." "$dir/"
      ;;
  esac
  echo "::endgroup::"
  for mode in release profile; do
    echo "::group::build $app $mode"
    dest="$out/$app/$mode"
    mkdir -p "$dest"
    log="$dest/build.log"
    if ! (cd "$dir" && flutter build ios "--$mode" --no-codesign -v >"$log" 2>&1); then
      tail -150 "$log"
      echo "::error::flutter build ios --$mode failed for $app"
      exit 1
    fi
    (cd "$repo" && dart run xcross_gen_snapshot:verify \
      --flutter-log "$log" \
      --copy-dill "$dest/app.dill" \
      --work "$work/official-$app-$mode" \
      --json "$dest/official.json")
    echo "::endgroup::"
  done
done

echo "Official App sha256 per corpus app:"
for app in "${apps[@]}"; do
  for mode in release profile; do
    f="$out/$app/$mode/official.json"
    printf '%-12s %-8s %s (%s bytes, dill %s bytes)\n' "$app" "$mode" \
      "$(sed -n 's/.*"app_sha256": "\([0-9a-f]*\)".*/\1/p' "$f")" \
      "$(sed -n 's/.*"app_size": \([0-9]*\).*/\1/p' "$f")" \
      "$(wc -c <"$out/$app/$mode/app.dill" | tr -d ' ')"
  done
done
