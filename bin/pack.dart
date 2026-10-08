import 'dart:io';

import 'package:args/args.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

/// Packs a build output directory into `gen_snapshot-<mode>-<host>.zip`.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('dir', mandatory: true, help: 'Output of the build command')
    ..addOption('mode', allowed: ['release', 'profile'], mandatory: true)
    ..addOption('host', help: 'Host id (default: this host)')
    ..addOption('out-dir', defaultsTo: '.', help: 'Where to write the zip');
  final options = parser.parse(args);
  final host = options.option('host') == null
      ? Host.current()
      : Host.parse(options.option('host')!);
  final mode = BuildMode.parse(options.option('mode')!);
  final bytes = packBuildOutput(Directory(options.option('dir')!), host);
  final info = AssetInfo.inspect(bytes, host);
  final zip = File('${options.option('out-dir')}/${assetName(mode, host)}')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  log(
    'wrote ${zip.path} (${info.size} bytes, sha256 ${info.sha256}, '
    'executable ${info.executableSha256})',
  );
  stdout.writeln(zip.path);
}
