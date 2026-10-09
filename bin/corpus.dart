import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

const usage =
    'dart run xcross_gen_snapshot:corpus '
    '(--samples-app <app dir> [--flutter-root <dir>] | '
    '--stress-generated <file>)';

/// Generates the sources of the corpus apps (docs/CORPUS.md).
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'samples-app',
      help:
          'A `flutter create` app to turn into the API samples app: copies '
          "every sample of Flutter's examples/api/lib into lib/samples and "
          'writes lib/main.dart',
    )
    ..addOption(
      'flutter-root',
      help: 'Flutter checkout providing examples/api (default: FLUTTER_ROOT)',
    )
    ..addOption(
      'stress-generated',
      help: 'Write the generated part of the stress app to this file',
    )
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
  final samplesApp = options.option('samples-app');
  final stressGenerated = options.option('stress-generated');
  if ((samplesApp == null) == (stressGenerated == null)) {
    stderr.writeln(
      'pass exactly one of --samples-app/--stress-generated\n$usage',
    );
    exit(64);
  }
  if (stressGenerated != null) {
    File(stressGenerated)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(renderStressGenerated());
    log('wrote $stressGenerated');
    return;
  }
  final root =
      options.option('flutter-root') ?? Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    stderr.writeln('missing --flutter-root (and FLUTTER_ROOT is not set)');
    exit(64);
  }
  final count = writeSamplesApp(
    samplesLib: Directory(p.join(root, 'examples', 'api', 'lib')),
    app: Directory(samplesApp!),
  );
  log('wrote $count API sample libraries into $samplesApp');
  stdout.writeln(count);
}
