import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

/// Writes manifest.json (docs/CONTRACT.md) for a directory holding all eight
/// compiler zips.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('flutter', mandatory: true)
    ..addOption('engine', mandatory: true)
    ..addOption('dart', mandatory: true)
    ..addOption('assets', mandatory: true, help: 'Directory with the zips')
    ..addOption('patch', defaultsTo: 'patches/dart_sdk.patch')
    ..addOption('release-app-sha256', mandatory: true)
    ..addOption('profile-app-sha256', mandatory: true)
    ..addOption('out', defaultsTo: 'manifest.json');
  final options = parser.parse(args);
  final dir = options.option('assets')!;
  final assets = <String, AssetInfo>{};
  for (final mode in BuildMode.values) {
    for (final host in Host.values) {
      final name = assetName(mode, host);
      final file = File(p.join(dir, name));
      if (!file.existsSync()) throw StateError('missing asset ${file.path}');
      assets[name] = AssetInfo.inspect(file.readAsBytesSync(), host);
    }
  }
  final manifest = buildManifest(
    release: FlutterRelease(
      flutter: options.option('flutter'),
      engine: options.option('engine')!,
      dart: options.option('dart')!,
    ),
    patchSha256: await sha256File(File(options.option('patch')!)),
    assets: assets,
    releaseAppSha256: options.option('release-app-sha256')!.trim(),
    profileAppSha256: options.option('profile-app-sha256')!.trim(),
  );
  File(options.option('out')!).writeAsStringSync(encodeManifest(manifest));
  stdout.write(encodeManifest(manifest));
}
