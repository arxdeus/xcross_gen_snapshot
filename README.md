# xcross_gen_snapshot

Prebuilt iOS arm64 AOT compilers (`gen_snapshot`) for Linux and Windows hosts, used by [xcross](https://github.com/arxdeus/xcross) to build Flutter iOS release and profile apps without macOS.

Flutter only publishes the iOS `gen_snapshot` for macOS hosts. This repository builds the same compiler from the Dart SDK revision pinned by each Flutter engine, for `linux-x64`, `linux-arm64`, `windows-x64` and `windows-arm64`, and checks in CI that its output is byte-identical to the official macOS compiler.

See `docs/RECIPE.md` for the build recipe and the evidence behind it.
