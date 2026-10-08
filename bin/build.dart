import 'dart:io';

import 'package:args/args.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

const usage =
    'dart run xcross_gen_snapshot:build '
    '(--flutter <version> | --engine <hash>) --mode release|profile '
    '--out <dir> [--work <dir>] [--cache <dir>] [--jobs N]';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('flutter', help: 'Flutter version tag, e.g. 3.47.0')
    ..addOption('engine', help: 'Flutter engine hash (engine.version)')
    ..addOption(
      'dart',
      help:
          'Dart SDK revision; skips network resolution when given with '
          '--engine',
    )
    ..addOption('mode', allowed: ['release', 'profile'], mandatory: true)
    ..addOption('out', mandatory: true, help: 'Output directory')
    ..addOption('work', defaultsTo: 'work', help: 'Scratch directory')
    ..addOption(
      'cache',
      help: 'Download cache directory (default: <work>/cache)',
    )
    ..addOption('jobs', help: 'ninja -j value')
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
  final flutter = options.option('flutter');
  final engine = options.option('engine');
  if ((flutter == null) == (engine == null)) {
    stderr.writeln('pass exactly one of --flutter or --engine\n$usage');
    exit(64);
  }
  final net = Net();
  final FlutterRelease release;
  try {
    final dart = options.option('dart');
    release = flutter != null
        ? await resolveFlutterVersion(net, flutter)
        : dart != null
        ? FlutterRelease(engine: engine!, dart: dart)
        : await resolveEngine(net, engine!);
  } finally {
    net.close();
  }
  final work = Directory(options.option('work')!).absolute;
  final cache = options.option('cache');
  final jobs = options.option('jobs');
  await buildGenSnapshot(
    release: release,
    mode: BuildMode.parse(options.option('mode')!),
    outDir: Directory(options.option('out')!).absolute,
    workDir: work,
    cacheDir: cache == null ? null : Directory(cache).absolute,
    jobs: jobs == null ? null : int.parse(jobs),
  );
}
