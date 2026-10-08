import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'config.dart';
import 'io.dart';
import 'resolve.dart';
import 'source.dart';

/// Result of [buildGenSnapshot].
class BuildResult {
  BuildResult({
    required this.executable,
    required this.executableSha256,
    required this.release,
    required this.mode,
    required this.host,
  });

  final File executable;
  final String executableSha256;
  final FlutterRelease release;
  final BuildMode mode;
  final Host host;

  Map<String, Object?> toJson() => {
    'flutter': release.flutter,
    'engine': release.engine,
    'dart': release.dart,
    'mode': mode.name,
    'host': host.id,
    'executable': p.basename(executable.path),
    'executable_sha256': executableSha256,
  };
}

/// Builds the iOS arm64 gen_snapshot for [release] in [mode] on this host and
/// copies it plus its licenses into [outDir].
Future<BuildResult> buildGenSnapshot({
  required FlutterRelease release,
  required BuildMode mode,
  required Directory outDir,
  required Directory workDir,
  Directory? cacheDir,
  int? jobs,
  String? python,
}) async {
  final host = Host.current();
  python ??= Platform.isWindows ? 'python' : 'python3';
  cacheDir ??= Directory(p.join(workDir.path, 'cache'));
  final client = http.Client();
  final net = Net(client: client);
  try {
    log(
      'building gen_snapshot ${mode.name} for ${host.id}: '
      'Flutter ${release.flutter ?? '?'} engine ${release.engine} '
      'Dart ${release.dart}',
    );
    final tree = await prepareSource(
      net: net,
      client: client,
      workDir: workDir,
      cacheDir: cacheDir,
      dartRevision: release.dart,
      host: host,
      python: python,
    );

    final outName = 'out/xgs_${mode.name}';
    final outPath = tree.path(outName);
    Directory(outPath).createSync(recursive: true);
    File(p.join(outPath, 'args.gn')).writeAsStringSync(
      renderArgsGn(host: host, mode: mode, dartRevision: release.dart),
    );

    final environment = <String, String>{
      if (host.isWindows) ...await _windowsToolchainEnvironment(),
    };
    final gn = tree.path(
      p.join('buildtools', 'xgs-gn', host.isWindows ? 'gn.exe' : 'gn'),
    );
    final ninja = tree.path(
      p.join('buildtools', 'ninja', host.isWindows ? 'ninja.exe' : 'ninja'),
    );
    await run(
      gn,
      ['gen', outName, '--root-target=//runtime/bin:gen_snapshot'],
      workingDirectory: tree.root.path,
      environment: environment,
    );
    await run(
      ninja,
      ['-C', outName, if (jobs != null) '-j$jobs', 'gen_snapshot'],
      workingDirectory: tree.root.path,
      environment: environment,
    );

    final built = File(
      host.isWindows
          ? p.join(outPath, 'gen_snapshot.exe')
          // The linux toolchain writes a stripped copy next to the unstripped
          // binary; ship the stripped one (same code, no debug info).
          : p.join(outPath, 'exe.stripped', 'gen_snapshot'),
    );
    if (!built.existsSync()) {
      throw StateError('ninja succeeded but ${built.path} is missing');
    }

    outDir.createSync(recursive: true);
    final executable = File(p.join(outDir.path, host.executableName));
    built.copySync(executable.path);
    if (!host.isWindows) await run('chmod', ['755', executable.path]);
    await _copyLicenses(tree, mode, Directory(p.join(outDir.path, 'licenses')));

    final result = BuildResult(
      executable: executable,
      executableSha256: await sha256File(executable),
      release: release,
      mode: mode,
      host: host,
    );
    File(p.join(outDir.path, 'build.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({...result.toJson(), 'pins': tree.pins.describe()})}\n',
    );
    log('built ${executable.path} (sha256 ${result.executableSha256})');
    return result;
  } finally {
    client.close();
  }
}

Future<void> _copyLicenses(
  SourceTree tree,
  BuildMode mode,
  Directory dest,
) async {
  dest.createSync(recursive: true);
  licenseSources(mode).forEach((name, relative) {
    final source = File(tree.path(relative));
    if (!source.existsSync()) {
      throw StateError('license file $relative is missing');
    }
    source.copySync(p.join(dest.path, 'LICENSE.$name'));
  });
  final pkg = await packageRoot();
  File(
    p.join(pkg.path, 'licenses', 'LICENSE.apple-libc-qsort'),
  ).copySync(p.join(dest.path, 'LICENSE.apple-libc-qsort'));
}

/// Environment for Dart's build/toolchain/win scripts: use the Visual Studio
/// installed on the machine (not depot_tools' packaged toolchain).
Future<Map<String, String>> _windowsToolchainEnvironment() async {
  var vs = Platform.environment['GYP_MSVS_OVERRIDE_PATH'];
  if (vs == null || vs.isEmpty) {
    final vswhere = p.join(
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
      'Microsoft Visual Studio',
      'Installer',
      'vswhere.exe',
    );
    vs = await capture(vswhere, [
      '-latest',
      '-products',
      '*',
      '-property',
      'installationPath',
    ]);
    if (vs.isEmpty) throw StateError('no Visual Studio with VC tools found');
  }
  log('using Visual Studio at $vs');
  return {
    'DEPOT_TOOLS_WIN_TOOLCHAIN': '0',
    'GYP_MSVS_OVERRIDE_PATH': vs,
    // build/vs_toolchain.py only knows VS 2017-2022 by year. Newer installs
    // (e.g. VS 2026 at "...\Microsoft Visual Studio\18\...") are found
    // through this override and treated as 2022, which they are compatible
    // with for building.
    'vs2022_install': vs,
  };
}
