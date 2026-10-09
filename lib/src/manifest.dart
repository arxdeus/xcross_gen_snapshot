import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder, getCrc32;
import 'package:path/path.dart' as p;

import 'config.dart';
import 'io.dart';
import 'resolve.dart';

/// Asset name of a compiler zip, e.g. `gen_snapshot-release-linux-x64.zip`.
String assetName(BuildMode mode, Host host) =>
    'gen_snapshot-${mode.name}-${host.id}.zip';

/// All compiler asset names a complete release has.
List<String> allAssetNames() => [
  for (final mode in BuildMode.values)
    for (final host in Host.values) assetName(mode, host),
];

/// A file to store in a zip.
class ZipEntry {
  ZipEntry(this.name, this.data, {this.executable = false});

  final String name;
  final List<int> data;
  final bool executable;
}

/// Writes a deterministic zip (fixed timestamps, sorted entries, Unix
/// "version made by" so the executable bit survives `unzip`).
Uint8List encodeZip(List<ZipEntry> entries) {
  final sorted = [...entries]..sort((a, b) => a.name.compareTo(b.name));
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  // 1980-01-01 00:00:00 in DOS format.
  const dosTime = 0;
  const dosDate = (0 << 9) | (1 << 5) | 1;
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  for (final e in sorted) {
    final name = utf8.encode(e.name);
    final crc = getCrc32(e.data);
    final compressed = ZLibCodec(raw: true, level: 9).encode(e.data);
    final offset = out.length;
    if (offset > 0xffffffff || e.data.length > 0xffffffff) {
      throw UnsupportedError('zip64 is not supported');
    }
    // Local file header.
    u32(out, 0x04034b50);
    u16(out, 20); // version needed
    u16(out, 0x0800); // UTF-8 names
    u16(out, 8); // deflate
    u16(out, dosTime);
    u16(out, dosDate);
    u32(out, crc);
    u32(out, compressed.length);
    u32(out, e.data.length);
    u16(out, name.length);
    u16(out, 0);
    out.add(name);
    out.add(compressed);
    // Central directory header.
    final mode = 0x8000 | (e.executable ? 0x1ed : 0x1a4); // regular file
    u32(central, 0x02014b50);
    u16(central, (3 << 8) | 20); // made by: Unix
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 8);
    u16(central, dosTime);
    u16(central, dosDate);
    u32(central, crc);
    u32(central, compressed.length);
    u32(central, e.data.length);
    u16(central, name.length);
    u16(central, 0); // extra
    u16(central, 0); // comment
    u16(central, 0); // disk
    u16(central, 0); // internal attrs
    u32(central, mode << 16);
    u32(central, offset);
    central.add(name);
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, sorted.length);
  u16(out, sorted.length);
  u32(out, centralBytes.length);
  u32(out, centralOffset);
  u16(out, 0);
  return out.takeBytes();
}

/// Packs a build output directory (executable + `licenses/`) into the
/// release zip layout of docs/CONTRACT.md.
Uint8List packBuildOutput(Directory dir, Host host) {
  final executable = File(p.join(dir.path, host.executableName));
  if (!executable.existsSync()) {
    throw StateError('${executable.path} is missing');
  }
  final entries = [
    ZipEntry(
      host.executableName,
      executable.readAsBytesSync(),
      executable: true,
    ),
  ];
  final licenses = Directory(p.join(dir.path, 'licenses'));
  if (!licenses.existsSync()) throw StateError('${licenses.path} is missing');
  for (final f in licenses.listSync().whereType<File>()) {
    entries.add(
      ZipEntry('licenses/${p.basename(f.path)}', f.readAsBytesSync()),
    );
  }
  return encodeZip(entries);
}

/// Hash/size facts of one compiler zip, as listed in the manifest.
class AssetInfo {
  AssetInfo({
    required this.sha256,
    required this.executableSha256,
    required this.size,
  });

  /// Inspects [zipBytes] of a compiler asset built for [host].
  factory AssetInfo.inspect(List<int> zipBytes, Host host) {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final executables = archive.files
        .where((f) => f.isFile && f.name == host.executableName)
        .toList();
    if (executables.length != 1) {
      throw StateError(
        'zip must contain exactly one ${host.executableName} '
        'at its root',
      );
    }
    final unexpected = archive.files.where(
      (f) =>
          f.isFile &&
          f.name != host.executableName &&
          !f.name.startsWith('licenses/'),
    );
    if (unexpected.isNotEmpty) {
      throw StateError(
        'unexpected files in zip: '
        '${unexpected.map((f) => f.name).join(', ')}',
      );
    }
    if (!archive.files.any((f) => f.name.startsWith('licenses/'))) {
      throw StateError('zip has no licenses/');
    }
    return AssetInfo(
      sha256: sha256Bytes(zipBytes),
      executableSha256: sha256Bytes(executables.single.readBytes()!),
      size: zipBytes.length,
    );
  }

  final String sha256;
  final String executableSha256;
  final int size;

  Map<String, Object?> toJson() => {
    'sha256': sha256,
    'executable_sha256': executableSha256,
    'size': size,
  };
}

/// Builds the `manifest.json` document of docs/CONTRACT.md.
Map<String, Object?> buildManifest({
  required FlutterRelease release,
  required String patchSha256,
  required Map<String, AssetInfo> assets,
  required String releaseAppSha256,
  required String profileAppSha256,
}) {
  final flutter = release.flutter;
  if (flutter == null) {
    throw ArgumentError('a release manifest needs the Flutter version');
  }
  final expected = allAssetNames().toSet();
  final actual = assets.keys.toSet();
  if (expected.length != actual.length || !expected.containsAll(actual)) {
    throw StateError(
      'assets must be exactly ${expected.toList()..sort()}, '
      'got ${actual.toList()..sort()}',
    );
  }
  for (final hash in [patchSha256, releaseAppSha256, profileAppSha256]) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw ArgumentError.value(hash, 'sha256');
    }
  }
  final names = assets.keys.toList()..sort();
  return {
    'schema': 1,
    'flutter': flutter,
    'engine': release.engine,
    'dart': release.dart,
    'patch_sha256': patchSha256,
    'assets': {for (final n in names) n: assets[n]!.toJson()},
    'verification': {
      'reference_app': 'flutter create default app',
      'release_app_sha256': releaseAppSha256,
      'profile_app_sha256': profileAppSha256,
    },
  };
}

/// Canonical JSON text of a manifest (stable formatting for comparisons).
String encodeManifest(Map<String, Object?> manifest) =>
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';

/// Checks, before publishing, that every compiler listed in [manifest] was
/// the one verified: [verifications] maps an asset name to the result JSON
/// of its verify job (`bin/verify.dart --json`). Each must have run exactly
/// the executable the asset contains (`compiler_sha256 ==
/// executable_sha256`) and produced the official App of its mode.
void checkVerifications(
  Map<String, Object?> manifest,
  Map<String, Map<String, Object?>> verifications,
) {
  final assets = (manifest['assets'] as Map).cast<String, Object?>();
  final verification = (manifest['verification'] as Map)
      .cast<String, Object?>();
  final missing = assets.keys.where((n) => !verifications.containsKey(n));
  if (missing.isNotEmpty) {
    throw StateError('no verification result for ${missing.join(', ')}');
  }
  for (final mode in BuildMode.values) {
    for (final host in Host.values) {
      final name = assetName(mode, host);
      final asset = (assets[name] as Map).cast<String, Object?>();
      final result = verifications[name]!;
      final executable = asset['executable_sha256'];
      if (result['compiler_sha256'] != executable) {
        throw StateError(
          '$name: verified compiler sha256 ${result['compiler_sha256']} is '
          'not the published executable $executable',
        );
      }
      final app = verification['${mode.name}_app_sha256'];
      if (result['app_sha256'] != app) {
        throw StateError(
          '$name: App sha256 ${result['app_sha256']} is not the official '
          '$app',
        );
      }
    }
  }
}
