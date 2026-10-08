import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'io.dart';

/// gen_snapshot flags Flutter's `flutter build ios` passes for the arm64
/// App.framework (flutter_tools AOTSnapshotter, iOS, Flutter 3.47), with the
/// output paths replaced by fixed relative names. gen_snapshot embeds the
/// `--macho-object` path in the App binary (N_OSO stab), so reference and
/// candidate must run with the same names in their own directories.
const verificationFlags = [
  '--deterministic',
  '--snapshot_kind=app-aot-macho-dylib',
  '--macho=App',
  '--macho-object=app.o',
  '--macho-min-os-version=15.0',
  '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks',
  '--macho-install-name=@rpath/App.framework/App',
];

/// Result of compiling an app.dill with a gen_snapshot.
class SnapshotResult {
  SnapshotResult({
    required this.appSha256,
    required this.appSize,
    required this.objectSha256,
  });

  factory SnapshotResult.fromJson(Map<String, Object?> json) => SnapshotResult(
    appSha256: json['app_sha256'] as String,
    appSize: json['app_size'] as int,
    objectSha256: json['app_o_sha256'] as String?,
  );

  /// sha256 of the Mach-O `App` dylib (what ships in App.framework).
  final String appSha256;
  final int appSize;

  /// sha256 of `app.o`. Only informational: its DWARF producer string names
  /// the host the compiler runs on.
  final String? objectSha256;

  Map<String, Object?> toJson() => {
    'app_sha256': appSha256,
    'app_size': appSize,
    'app_o_sha256': objectSha256,
  };
}

/// Runs [compiler] on [dill] with [verificationFlags] inside [workDir] and
/// returns the hashes of the outputs.
Future<SnapshotResult> compileApp({
  required File compiler,
  required File dill,
  required Directory workDir,
}) async {
  if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  workDir.createSync(recursive: true);
  final args = [...verificationFlags, dill.absolute.path];
  log('\$ ${compiler.path} ${args.join(' ')}   (in ${workDir.path})');
  final result = await Process.run(
    compiler.absolute.path,
    args,
    workingDirectory: workDir.path,
  );
  stderr.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(
      compiler.path,
      args,
      'gen_snapshot failed',
      result.exitCode,
    );
  }
  final app = File(p.join(workDir.path, 'App'));
  final object = File(p.join(workDir.path, 'app.o'));
  if (!app.existsSync()) throw StateError('gen_snapshot produced no App');
  return SnapshotResult(
    appSha256: await sha256File(app),
    appSize: app.lengthSync(),
    objectSha256: object.existsSync() ? await sha256File(object) : null,
  );
}

/// The gen_snapshot invocation found in a `flutter build ios -v` log.
class LoggedInvocation {
  LoggedInvocation(this.compiler, this.flags, this.dill);

  final String compiler;
  final List<String> flags;
  final String dill;
}

/// Finds the arm64 gen_snapshot invocation in a `flutter build ios -v` log
/// and checks that, apart from the output paths, its flags are exactly
/// [verificationFlags]. This keeps the verification honest if a future
/// Flutter version changes how it calls gen_snapshot.
LoggedInvocation parseFlutterBuildLog(String log) {
  final lines = const LineSplitter()
      .convert(log)
      .where((l) => l.contains('executing: ') && l.contains('gen_snapshot'))
      .toList();
  if (lines.length != 1) {
    throw StateError(
      'expected exactly one gen_snapshot invocation in the '
      'flutter build log, found ${lines.length}',
    );
  }
  final command = lines.single
      .substring(lines.single.indexOf('executing: ') + 11)
      .trim();
  // flutter_tools logs the arguments joined by spaces; none of the paths in
  // a CI workspace contain spaces.
  final parts = command.split(' ').where((s) => s.isNotEmpty).toList();
  if (parts.length < 3) throw StateError('cannot parse: $command');
  final compiler = parts.first;
  final dill = parts.last;
  final flags = parts.sublist(1, parts.length - 1);
  final normalized = [
    for (final f in flags)
      if (f.startsWith('--macho='))
        '--macho=App'
      else if (f.startsWith('--macho-object='))
        '--macho-object=app.o'
      else
        f,
  ];
  if (normalized.join(' ') != verificationFlags.join(' ')) {
    throw StateError(
      'flutter invoked gen_snapshot with different flags:\n'
      '  logged:   ${normalized.join(' ')}\n'
      '  expected: ${verificationFlags.join(' ')}',
    );
  }
  if (!dill.endsWith('app.dill')) {
    throw StateError('unexpected kernel input $dill');
  }
  return LoggedInvocation(compiler, flags, dill);
}
