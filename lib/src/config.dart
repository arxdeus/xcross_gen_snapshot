import 'dart:ffi' show Abi;

/// Compilation mode of the produced compiler (Flutter's `ios-release` or
/// `ios-profile` gen_snapshot).
enum BuildMode {
  release,
  profile;

  static BuildMode parse(String value) => BuildMode.values.firstWhere(
    (m) => m.name == value,
    orElse: () =>
        throw ArgumentError.value(value, 'mode', 'expected release or profile'),
  );
}

/// A host the compiler is built for (and on: builds are always native).
enum Host {
  linuxX64('linux-x64', 'linux', 'x64'),
  linuxArm64('linux-arm64', 'linux', 'arm64'),
  windowsX64('windows-x64', 'win', 'x64'),
  windowsArm64('windows-arm64', 'win', 'arm64');

  const Host(this.id, this.gnOs, this.gnCpu);

  /// Name used in asset names, e.g. `linux-x64`.
  final String id;

  /// GN `target_os` / `host_os`.
  final String gnOs;

  /// GN `target_cpu` / `host_cpu`.
  final String gnCpu;

  bool get isWindows => gnOs == 'win';

  String get executableName => isWindows ? 'gen_snapshot.exe' : 'gen_snapshot';

  /// CIPD platform name of the native package (`${{platform}}`).
  String get cipdPlatform => switch (this) {
    Host.linuxX64 => 'linux-amd64',
    Host.linuxArm64 => 'linux-arm64',
    Host.windowsX64 => 'windows-amd64',
    Host.windowsArm64 => 'windows-arm64',
  };

  /// CIPD platform of the clang and gn packages. Neither is published for
  /// windows-arm64, so that host runs the x64 binaries under emulation,
  /// exactly like Dart's own DEPS does.
  String get toolCipdPlatform =>
      this == Host.windowsArm64 ? 'windows-amd64' : cipdPlatform;

  /// Where Dart's GN expects clang (`//buildtools/<dir>/clang`).
  String get clangDir => switch (this) {
    Host.linuxX64 => 'buildtools/linux-x64/clang',
    Host.linuxArm64 => 'buildtools/linux-arm64/clang',
    // clang_base_path defaults to //buildtools/win-x64/clang on Windows,
    // also on arm64 hosts.
    Host.windowsX64 || Host.windowsArm64 => 'buildtools/win-x64/clang',
  };

  /// Where Dart's DEPS deploys gn (`buildtools/gn` or `buildtools/win/gn.exe`).
  String get gnDir => isWindows ? 'buildtools/win' : 'buildtools';

  static Host parse(String id) => Host.values.firstWhere(
    (h) => h.id == id,
    orElse: () => throw ArgumentError.value(id, 'host', 'unknown host'),
  );

  /// The host this process runs on.
  static Host current() => switch (Abi.current()) {
    Abi.linuxX64 => Host.linuxX64,
    Abi.linuxArm64 => Host.linuxArm64,
    Abi.windowsX64 => Host.windowsX64,
    Abi.windowsArm64 => Host.windowsArm64,
    final abi => throw UnsupportedError(
      'gen_snapshot can only be built on linux/windows x64/arm64 hosts '
      '(this is $abi)',
    ),
  };
}

/// Renders `args.gn` for building the iOS arm64 gen_snapshot on [host]
/// (docs/RECIPE.md "GN args").
String renderArgsGn({
  required Host host,
  required BuildMode mode,
  required String dartRevision,
}) {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(dartRevision)) {
    throw ArgumentError.value(dartRevision, 'dartRevision', 'not a git sha');
  }
  final args = <String, Object>{
    'target_os': host.gnOs,
    'target_cpu': host.gnCpu,
    'host_cpu': host.gnCpu,
    'dart_target_arch': 'arm64',
    'dart_use_compressed_pointers': false,
    'is_debug': false,
    'dart_debug': false,
    'is_release': mode == BuildMode.profile,
    'is_product': mode == BuildMode.release,
    'dart_runtime_mode': mode.name,
    'dart_default_optimization_level': '2',
    'dart_component_kind': 'static_library',
    'dart_lib_export_symbols': false,
    'dart_version_git_info': true,
    'verify_sdk_hash': true,
    'dart_sdk_verification_hash': dartRevision.substring(0, 10),
    'exclude_kernel_service': false,
    'is_clang': true,
    'dart_vm_code_coverage': false,
    'dart_dynamic_modules': false,
    if (!host.isWindows) 'dart_sysroot': 'debian',
    'dart_xcross_target_os_ios': true,
  };
  final buf = StringBuffer();
  args.forEach((key, value) {
    final rendered = value is String ? '"$value"' : '$value';
    buf.writeln('$key = $rendered');
  });
  return buf.toString();
}
