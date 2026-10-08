import 'deps.dart';
import 'io.dart';

/// A Flutter version and the engine/Dart revisions it pins.
class FlutterRelease {
  const FlutterRelease({
    this.flutter,
    required this.engine,
    required this.dart,
  });

  /// Flutter version tag (e.g. `3.47.0`); null when resolved from an engine.
  final String? flutter;

  /// Engine hash (`bin/internal/engine.version`).
  final String engine;

  /// Dart SDK revision (`dart_revision` in the Flutter DEPS).
  final String dart;

  Map<String, Object?> toJson() => {
    'flutter': flutter,
    'engine': engine,
    'dart': dart,
  };

  @override
  String toString() => 'Flutter ${flutter ?? '?'} engine $engine dart $dart';
}

final _sha = RegExp(r'^[0-9a-f]{40}$');

/// Whether [tag] looks like a stable Flutter version tag (`3.47.0`).
bool isFlutterVersionTag(String tag) =>
    RegExp(r'^\d+\.\d+\.\d+$').hasMatch(tag);

Uri _raw(String ref, String path) =>
    Uri.parse('https://raw.githubusercontent.com/flutter/flutter/$ref/$path');

/// Resolves the engine and Dart revision of the Flutter tag [version].
Future<FlutterRelease> resolveFlutterVersion(Net net, String version) async {
  if (!isFlutterVersionTag(version)) {
    throw ArgumentError.value(version, 'flutter', 'not a Flutter version tag');
  }
  final engine = (await net.getString(
    _raw(version, 'bin/internal/engine.version'),
  )).trim();
  if (!_sha.hasMatch(engine)) {
    throw StateError('Flutter $version has an invalid engine.version: $engine');
  }
  final dart = dartRevisionFromFlutterDeps(
    await net.getString(_raw(version, 'DEPS')),
  );
  // The engine is built from the monorepo commit named by engine.version, so
  // that commit's DEPS is what really pins Dart. Check they agree.
  final engineDart = dartRevisionFromFlutterDeps(
    await net.getString(_raw(engine, 'DEPS')),
  );
  if (engineDart != dart) {
    throw StateError(
      'Flutter $version DEPS pins Dart $dart but its engine '
      '$engine pins $engineDart',
    );
  }
  return FlutterRelease(flutter: version, engine: engine, dart: dart);
}

/// Resolves the Dart revision of the engine (monorepo commit) [engine].
Future<FlutterRelease> resolveEngine(Net net, String engine) async {
  if (!_sha.hasMatch(engine)) {
    throw ArgumentError.value(engine, 'engine', 'not a 40-char git sha');
  }
  final dart = dartRevisionFromFlutterDeps(
    await net.getString(_raw(engine, 'DEPS')),
  );
  return FlutterRelease(engine: engine, dart: dart);
}
