import 'dart:io';

import 'package:path/path.dart' as p;

import 'io.dart';

/// Identity of the machine a build or reference compile ran on: GitHub's
/// runner image (`ImageOS`/`ImageVersion`) and the OS version, so drift of
/// the runner images between releases is visible in the recorded JSON.
Future<Map<String, Object?>> runnerIdentity() async {
  final env = Platform.environment;
  return {
    'image_os': env['ImageOS'],
    'image_version': env['ImageVersion'],
    'runner_os': env['RUNNER_OS'],
    'runner_arch': env['RUNNER_ARCH'],
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    if (Platform.isMacOS) ...await _macosIdentity(),
  };
}

Future<Map<String, Object?>> _macosIdentity() async {
  Future<String?> tryCapture(String exe, List<String> args) async {
    try {
      return await capture(exe, args);
    } on Object {
      return null;
    }
  }

  final xcode = await tryCapture('xcodebuild', ['-version']);
  return {
    'macos_product_version': await tryCapture('sw_vers', ['-productVersion']),
    'macos_build_version': await tryCapture('sw_vers', ['-buildVersion']),
    'xcode': xcode?.split('\n').join(' '),
  };
}

/// Versions of the MSVC tools and Windows SDK a Windows build used, read
/// from the INCLUDE/LIB paths of an environment block written by Dart's
/// `build/toolchain/win/setup_toolchain.py` (`<out>/environment.<cpu>`).
Map<String, String?> parseWindowsEnvironmentBlock(String block) {
  String? include;
  String? lib;
  for (final entry in block.split('\u0000')) {
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final key = entry.substring(0, eq).toLowerCase();
    if (key == 'include') include = entry.substring(eq + 1);
    if (key == 'lib') lib = entry.substring(eq + 1);
  }
  final paths = '${include ?? ''};${lib ?? ''}';
  String? match(RegExp re) => re.firstMatch(paths)?.group(1);
  return {
    'msvc_tools_version': match(
      RegExp(r'[\\/]VC[\\/]Tools[\\/]MSVC[\\/]([0-9.]+)', caseSensitive: false),
    ),
    'windows_sdk_version': match(
      RegExp(
        r'[\\/]Windows Kits[\\/]10[\\/](?:include|lib)[\\/]([0-9.]+)',
        caseSensitive: false,
      ),
    ),
  };
}

/// Identity of the Windows toolchain of a build in [outDir] (the GN output
/// directory): the Visual Studio instance (vswhere) at [visualStudio] and
/// the MSVC tools / Windows SDK versions GN's toolchain setup selected.
Future<Map<String, Object?>> windowsToolchainIdentity({
  required String visualStudio,
  required String outDir,
}) async {
  final vs = <String, Object?>{'installation_path': visualStudio};
  final vswhere = vswherePath();
  for (final property in [
    'displayName',
    'installationVersion',
    'catalog_productDisplayVersion',
  ]) {
    try {
      vs[property] = await capture(vswhere, [
        '-path',
        visualStudio,
        '-property',
        property,
      ]);
    } on Object catch (e) {
      log('vswhere -property $property failed: $e');
      vs[property] = null;
    }
  }
  final blocks =
      Directory(outDir)
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('environment.'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return {
    'visual_studio': vs,
    'environments': {
      for (final f in blocks)
        p.basename(f.path): parseWindowsEnvironmentBlock(f.readAsStringSync()),
    },
  };
}

/// Location of vswhere.exe (installed with every Visual Studio 2017+).
String vswherePath() => p.join(
  Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
  'Microsoft Visual Studio',
  'Installer',
  'vswhere.exe',
);
