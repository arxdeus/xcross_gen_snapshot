import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:args/args.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

const usage =
    'dart run xcross_gen_snapshot:verify '
    '(--compiler <gen_snapshot> --dill <app.dill> | --flutter-log <log>) '
    '[--work <dir>] [--expect <sha256>] [--json <file>]';

/// Compiles an app.dill with a gen_snapshot using Flutter's iOS flags and
/// fixed relative output names, prints the sha256 of the App binary and
/// optionally checks it against --expect.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('compiler', help: 'gen_snapshot to run')
    ..addOption('dill', help: 'Kernel file (app.dill)')
    ..addOption(
      'flutter-log',
      help:
          'A `flutter build ios -v` log; takes --compiler and --dill '
          'from its gen_snapshot invocation (after checking its flags)',
    )
    ..addOption('copy-dill', help: 'Copy the dill used here (for artifacts)')
    ..addOption('work', defaultsTo: 'verify', help: 'Directory for outputs')
    ..addOption(
      'compiler-zip',
      help: 'A release zip; its gen_snapshot[.exe] is extracted and run',
    )
    ..addOption('expect', help: 'Required sha256 of App')
    ..addOption(
      'expect-json',
      help:
          'Take the required App sha256 from this result JSON (the '
          'output of --json on the reference run)',
    )
    ..addOption('json', help: 'Write the result as JSON to this file')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults options;
  try {
    options = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n$usage\n${parser.usage}');
    exit(64);
  }
  if (options.flag('help')) {
    stdout.writeln('$usage\n${parser.usage}');
    return;
  }
  var compiler = options.option('compiler');
  var dill = options.option('dill');
  final logPath = options.option('flutter-log');
  if (logPath != null) {
    final invocation = parseFlutterBuildLog(File(logPath).readAsStringSync());
    compiler ??= invocation.compiler;
    dill ??= invocation.dill;
    log('flutter used ${invocation.compiler} on ${invocation.dill}');
  }
  final zip = options.option('compiler-zip');
  if (zip != null) {
    final dir = Directory('${options.option('work')}-compiler').absolute;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    final archive = ZipDecoder().decodeBytes(File(zip).readAsBytesSync());
    await makeExecutable(extractEntries(archive, dir.path));
    final host = Host.current();
    final info = AssetInfo.inspect(File(zip).readAsBytesSync(), host);
    compiler = File('${dir.path}/${host.executableName}').path;
    log('extracted $compiler (sha256 ${info.executableSha256})');
  }
  if (compiler == null || dill == null) {
    stderr.writeln('missing --compiler/--dill\n$usage');
    exit(64);
  }
  final copyDill = options.option('copy-dill');
  if (copyDill != null) {
    File(copyDill).parent.createSync(recursive: true);
    File(dill).copySync(copyDill);
  }
  final result = await compileApp(
    compiler: File(compiler),
    dill: File(dill),
    workDir: Directory(options.option('work')!).absolute,
  );
  final json = {
    'compiler': compiler,
    'compiler_sha256': await sha256File(File(compiler)),
    'dill_sha256': await sha256File(File(dill)),
    ...result.toJson(),
  };
  final jsonPath = options.option('json');
  if (jsonPath != null) {
    File(jsonPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      );
  }
  stdout.writeln(result.appSha256);
  final expectJson = options.option('expect-json');
  final expected =
      options.option('expect') ??
      (expectJson == null
          ? null
          : SnapshotResult.fromJson(
              jsonDecode(File(expectJson).readAsStringSync())
                  as Map<String, Object?>,
            ).appSha256);
  if (expected != null) {
    if (expected.trim() != result.appSha256) {
      stderr.writeln(
        'MISMATCH: App sha256 ${result.appSha256}, '
        'expected ${expected.trim()}',
      );
      exit(1);
    }
    log('App is byte-identical to the reference (${result.appSha256})');
  }
}
