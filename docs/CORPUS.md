# Verification corpus

Every published compiler was first proven byte-identical to Flutter's
official macOS `gen_snapshot` on one app (the default `flutter create` app).
Host-dependent behavior (sort tie order, argument evaluation order under
MSVC-ABI clang, see RECIPE.md) only shows up on code that reaches it, so the
compilers are also proven on this corpus.

| app | what it is | source |
|---|---|---|
| `ref_app` | default `flutter create` app (the one the release manifests name) | `flutter create` |
| `api_samples` | every Flutter API sample (`examples/api/lib`, 579 libraries in 3.47) in one app: a generated `lib/main.dart` imports each sample library with a prefix and keeps all their `main` functions reachable through a list indexed at run time, so tree shaking keeps every sample | `dart run xcross_gen_snapshot:corpus --samples-app` |
| `stress` | hand-written: RegExp (named groups, unicode properties, lookbehind, case-insensitive classes, large alternations, run-time patterns), records/patterns, sealed classes, async*/sync*, extension types, dart:ffi structs/unions/packed/arrays/callbacks, big const maps/sets/lists, generics, closures, try/catch/finally, enums, mixins, SIMD, isolates; plus `generated.dart` (240 classes over 12 interfaces, many equal-popularity selectors, large const tables) | `corpus/stress` |
| `pub_heavy` | 28 pure Dart/Flutter packages (bloc, riverpod, provider, go_router, dio, intl, rxdart, petitparser, markdown, xml, yaml, fast_immutable_collections, built_collection, fpdart, ...), no plugins so `flutter build ios` needs no CocoaPods | `corpus/pub_heavy` |

Sizes with Flutter 3.47.0 (release): App 4.4 MB / 15.8 MB / 6.1 MB / 9.4 MB,
app.dill 23 / 51 / 28 / 40 MB.

The RegExp code is compiled at run time (irregexp is not part of the AOT
snapshot); the stress app keeps it to exercise the runtime library and for
when that changes.

## How it is used
- `tool/build_corpus.sh <work> <out> [app...]` (macOS, official Flutter on
  PATH): creates each app, runs `flutter build ios --release|--profile
  --no-codesign -v` and recompiles the app.dill flutter produced with
  Flutter's own gen_snapshot and the exact flags from the log
  (`verify --flutter-log --copy-dill --json`). Output:
  `<out>/<app>/<mode>/{app.dill,official.json,build.log}`.
- `tool/verify_corpus.sh <zip> <out> <mode> <results> [verify args]` (any
  host, run from the repo root): runs the compiler of `<zip>` on every
  corpus dill of `<mode>` and requires the official App sha256
  (`verify --compiler-zip --expect-json`, plus `--manifest <manifest.json>
  --flutter <version>` for published zips). Mismatching App/app.o land in
  `<results>/mismatch/<app>/`.
- `.github/workflows/verify_published.yml` (workflow_dispatch, input
  `flutter`): proves the published release of that Flutter version on the
  corpus without rebuilding anything.
  `gh workflow run verify_published.yml -R arxdeus/xcross_gen_snapshot --ref main -f flutter=3.47.6`

The kernel embeds `file://` URIs of the Flutter SDK in profile mode, so a
profile App depends on where Flutter is installed; only compare apps built
in the same place (the workflows always use `$RUNNER_TEMP/flutter`).

## Updating
- `corpus/stress/lib/generated.dart` is generated:
  `dart run xcross_gen_snapshot:corpus --stress-generated corpus/stress/lib/generated.dart`
  (a test checks it is up to date).
- `flutter analyze` the apps inside a created app (the repository's
  analysis_options exclude `corpus/`).
