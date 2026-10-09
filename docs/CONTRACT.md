# Contract between xcross_gen_snapshot and xcross (coordinator-owned, both workers follow it)

## Where compilers are built
- ONLY in GitHub Actions of arxdeus/xcross_gen_snapshot. Nobody builds release binaries locally, nobody uploads binaries by hand, and xcross never builds gen_snapshot on a user's machine.
- A release is produced by pushing a tag. The tag name IS the Flutter version, exactly as Flutter tags it (e.g. `3.47.0`, `3.47.6`). The workflow resolves engine + Dart revision from flutter/flutter at that tag, builds every host x mode, verifies byte-identity against the official macOS compiler, and only then publishes the GitHub release for that tag. Backfill = push tags `3.47.0` ... `3.47.6`.
- A published release is never replaced silently. Re-running the tag's workflow is a no-op if the new manifest equals the published one, finishes a draft left by an interrupted run, and fails if the release is published with a different manifest. The only way to overwrite a published release is a manual `workflow_dispatch` on main with `flutter=<tag>` and `replace_release=true`; it uploads the zips first and manifest.json last, so for a few seconds the published zips may not match the published manifest (xcross verifies every download against the manifest and fails closed then; retrying later succeeds).
- Every published zip and manifest.json has a GitHub build provenance attestation (`gh attestation verify <file> -R arxdeus/xcross_gen_snapshot`).

## Release layout (GitHub Releases of arxdeus/xcross_gen_snapshot)
- One release per Flutter version tag. Title: `Flutter <version> (engine <short engine>)`.
- Assets per release (8 compilers + manifest):
  - `gen_snapshot-<mode>-<host>.zip` with mode in {release, profile} and host in {linux-x64, linux-arm64, windows-x64, windows-arm64}.
  - Zip contents: a single executable `gen_snapshot` (Linux) or `gen_snapshot.exe` (Windows) at the zip root, plus license files under `licenses/`: Dart SDK, zlib, boringssl, icu, double-conversion and the BSD license of the Apple qsort/heapsort port in every zip, plus perfetto in the profile zips only (only the profile compiler links perfetto).
  - `manifest.json`:
    ```json
    {
      "schema": 1,
      "flutter": "3.47.0",
      "engine": "<engine hash>",
      "dart": "<dart revision>",
      "patch_sha256": "<sha256 of patches/dart_sdk.patch used>",
      "assets": {
        "gen_snapshot-release-linux-x64.zip": {"sha256": "<zip sha256>", "executable_sha256": "<sha256 of the extracted binary>", "size": 1234}
      },
      "verification": {
        "reference_app": "flutter create default app",
        "release_app_sha256": "<sha256 of App from the official macOS compiler, matched by every host build>",
        "profile_app_sha256": "<same for profile>"
      }
    }
    ```

## How xcross resolves a compiler (Linux/Windows hosts; macOS uses Flutter's own ios-release/ios-profile gen_snapshot_arm64)
1. Read the Flutter version (`$FLUTTER_ROOT/bin/cache/flutter.version.json` key `frameworkVersion`, else `$FLUTTER_ROOT/version`) and engine (`$FLUTTER_ROOT/bin/internal/engine.version`).
2. Local cache first: `<xcross cache root>/gen-snapshot/<engine>/<mode>/<host>/gen_snapshot[.exe]` + `meta.json` `{"flutter","engine","dart","mode","host","source":"download","executable_sha256"}`; reuse only if meta matches and the binary's sha256 equals executable_sha256. Only downloaded compilers are cached, so `source` is always `"download"`; a user-pinned compiler (step 3) is used in place and never copied into the cache.
3. User pin: if the user configured a compiler path for this Flutter version/engine in xcross config, use it (no download).
4. Download: `https://github.com/arxdeus/xcross_gen_snapshot/releases/download/<flutter version>/manifest.json`; 404 = no release. Require `manifest.engine == local engine` (a modified or mismatched SDK is treated as unavailable). Download `gen_snapshot-<mode>-<host>.zip`, verify zip sha256 and extracted executable sha256 from the manifest, cache it.
5. Otherwise fail with a clear message: no prebuilt iOS compiler for Flutter <version> (engine <short>); list published versions if cheap; explain how to pin a compiler path; point to the xcross_gen_snapshot repo.

## Build recipe
- docs/RECIPE.md (verified). Patch: patches/dart_sdk.patch.
