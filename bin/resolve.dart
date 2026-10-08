import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

/// Resolves a Flutter version tag to its engine and Dart revisions and the
/// pinned build inputs. Prints JSON; with --github-output also writes
/// `flutter`, `engine`, `dart` and `deps_key` step outputs.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('flutter', mandatory: true, help: 'Flutter version tag')
    ..addOption('github-output', help: r'Path of $GITHUB_OUTPUT');
  final options = parser.parse(args);
  final net = Net();
  try {
    final release = await resolveFlutterVersion(
      net,
      options.option('flutter')!,
    );
    final depsSource = await net.getString(
      Uri.parse(
        'https://raw.githubusercontent.com/dart-lang/sdk/${release.dart}/DEPS',
      ),
    );
    final deps = DartDeps.parse(depsSource);
    final pins = {
      for (final host in Host.values)
        host.id: Pins.fromDeps(deps, host).describe(),
    };
    final depsKey = sha256Bytes(utf8.encode(jsonEncode(pins))).substring(0, 16);
    final json = {...release.toJson(), 'deps_key': depsKey, 'pins': pins};
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(json));
    final out = options.option('github-output');
    if (out != null) {
      File(out).writeAsStringSync(
        'flutter=${release.flutter}\nengine=${release.engine}\n'
        'dart=${release.dart}\ndeps_key=$depsKey\n',
        mode: FileMode.append,
      );
    }
  } finally {
    net.close();
  }
}
