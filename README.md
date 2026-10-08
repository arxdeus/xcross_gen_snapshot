# xcross_gen_snapshot

Prebuilt iOS arm64 AOT compilers (`gen_snapshot`) for Linux and Windows hosts, used by [xcross](https://github.com/arxdeus/xcross) to build Flutter iOS release and profile apps without macOS.

Flutter only publishes the iOS `gen_snapshot` for macOS hosts. This repository builds the same compiler from the Dart SDK revision pinned by each Flutter engine, for `linux-x64`, `linux-arm64`, `windows-x64` and `windows-arm64`, and proves in CI that its output is byte-identical to the official macOS compiler.

## Releases

Every release is named after a Flutter version (`3.47.0`, ...) and has:

- `gen_snapshot-<release|profile>-<host>.zip`: the compiler (`gen_snapshot` or `gen_snapshot.exe`) plus `licenses/`.
- `manifest.json`: Flutter version, engine, Dart revision, sha256 of every zip and executable, and the sha256 of the `App` binary every compiler produced (see [docs/CONTRACT.md](docs/CONTRACT.md)).

Compilers are built only by GitHub Actions ([.github/workflows/gen_snapshot.yml](.github/workflows/gen_snapshot.yml)), never by hand.

### How a release is made

Push a tag named after the Flutter version:

```sh
git tag 3.47.7 && git push origin 3.47.7
```

The workflow then:

1. resolves the engine (`bin/internal/engine.version`) and Dart revision (`DEPS` `dart_revision`) of that Flutter tag,
2. on `macos-15`, installs that Flutter, builds the default `flutter create` app with `flutter build ios --release` and `--profile`, and recompiles the exact `app.dill` with Flutter's official `ios-release`/`ios-profile` `gen_snapshot_arm64` (flags taken from and checked against the `flutter build -v` log, outputs named `App`/`app.o`),
3. builds the compiler on all four hosts in both modes (the recipe below),
4. runs every built compiler on the same `app.dill` with the same flags on its own host and requires the `App` sha256 to equal the official one,
5. only then publishes the release with the 8 zips and `manifest.json`. Re-running a tag whose release already carries the identical manifest is a no-op.

To build and verify without publishing, run the workflow manually (Actions, `gen_snapshot`, "Run workflow") with a Flutter version.

## Tooling

A Dart package (`dart pub get` first):

```sh
# Build (on a linux/windows x64/arm64 host; CI does this)
dart run xcross_gen_snapshot:build --flutter 3.47.0 --mode release --out out [--work work] [--jobs N]
dart run xcross_gen_snapshot:build --engine <hash> --mode profile --out out

# Compile an app.dill with Flutter's iOS flags and print the sha256 of App
dart run xcross_gen_snapshot:verify --compiler out/gen_snapshot --dill app.dill [--expect <sha256>]

# Resolve a Flutter tag to engine/Dart and pinned inputs
dart run xcross_gen_snapshot:resolve --flutter 3.47.0
```

The build is pure Dart orchestration (git, python3 and the pinned CIPD toolchain are the only external tools): sparse shallow fetch of `dart-lang/sdk` at the revision, DEPS-pinned zlib/boringssl/icu/perfetto as gitiles tarballs, clang/gn/ninja/sysroot from CIPD over HTTPS (sha256-verified against the content address), [`patches/dart_sdk.patch`](patches/dart_sdk.patch) (+ [`patches/windows_host.patch`](patches/windows_host.patch) on Windows), `gn gen`, `ninja gen_snapshot`. See [docs/RECIPE.md](docs/RECIPE.md).
