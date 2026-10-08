# Contract between xcross_gen_snapshot and xcross (coordinator-owned, both workers follow it)

## Release layout (GitHub Releases of arxdeus/xcross_gen_snapshot)
- One release per Flutter engine hash. Tag: `engine-<40-char engine hash>` (e.g. `engine-5f77625673248ee5846fbcaf5d3e1a3878386fd7`). Title: `Flutter <versions> (engine <short>)`, e.g. `Flutter 3.47.3, 3.47.4 (engine 06a2e2a1)`.
- Assets per release (8 compilers + manifest):
  - `gen_snapshot-<mode>-<host>.zip` with mode in {release, profile} and host in {linux-x64, linux-arm64, windows-x64, windows-arm64}.
  - Zip contents: a single executable `gen_snapshot` (Linux) or `gen_snapshot.exe` (Windows) at the zip root, plus `LICENSE` files of Dart SDK and bundled third_party (zlib, boringssl, icu, double-conversion, perfetto for profile) and the BSD license of Apple's qsort/heapsort port, under `licenses/`.
  - `manifest.json`:
    ```json
    {
      "schema": 1,
      "engine": "<engine hash>",
      "dart": "<dart revision>",
      "flutter": ["3.47.3", "3.47.4"],
      "patch_sha256": "<sha256 of patches/dart_sdk.patch used>",
      "assets": {
        "gen_snapshot-release-linux-x64.zip": {"sha256": "<zip sha256>", "executable_sha256": "<sha256 of the extracted binary>", "size": 1234},
        "...": {}
      },
      "verification": {
        "reference_app": "flutter create default app",
        "release_app_sha256": "<sha256 of App produced by official macOS compiler and by every host build>",
        "profile_app_sha256": "<same for profile>"
      }
    }
    ```
- Optional repo-level index on the default branch: `index.json` = `{"schema":1,"engines":{"<engine>":{"flutter":["3.47.0"],"tag":"engine-<engine>"}}}`. xcross must NOT depend on it; it resolves by engine hash directly via the release tag URL.

## Download URLs xcross uses
- `https://github.com/arxdeus/xcross_gen_snapshot/releases/download/engine-<engine>/manifest.json`
- `https://github.com/arxdeus/xcross_gen_snapshot/releases/download/engine-<engine>/gen_snapshot-<mode>-<host>.zip`
- 404 on manifest.json = no prebuilt compiler for that engine.

## Local cache (xcross)
- `<xcross cache root>/gen-snapshot/<engine>/<mode>/<host>/gen_snapshot[.exe]` plus `meta.json` = `{"engine","dart","mode","host","source":"download"|"local-build","executable_sha256"}`.
- A cached compiler is reused only if meta.json matches engine/mode/host and the binary's sha256 equals executable_sha256.

## Build recipe
- See docs/RECIPE.md (verified). Patch: patches/dart_sdk.patch (applies at least to Dart da6595cd).
- The same recipe powers the local build fallback in xcross. Keep the recipe logic (source fetch, deps from DEPS, CIPD tools, GN args, ninja) in ONE Dart library inside xcross_gen_snapshot (`lib/`) usable as a CLI (`dart run xcross_gen_snapshot:build --engine <hash> --mode release --out <dir>`), so xcross can either vendor-copy the same steps or run it. Final decision for xcross: xcross reimplements the steps in its own `shared/` + `host/` code (no runtime dependency on this repo's Dart code), following the same recipe and GN args; both must stay in sync, documented in RECIPE.md.
