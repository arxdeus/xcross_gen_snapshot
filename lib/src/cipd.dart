import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'io.dart';

const cipdBackend = 'https://chrome-infra-packages.appspot.com';

/// A resolved CIPD package instance.
class CipdInstance {
  const CipdInstance({
    required this.package,
    required this.version,
    required this.instanceId,
    required this.sha256,
    required this.downloadUrl,
  });

  final String package;
  final String version;

  /// CIPD instance id (base64url of the content hash plus an algorithm byte),
  /// as recorded in `.versions/*.cipd_version` stamps.
  final String instanceId;

  /// Hex sha256 of the package zip, taken from the content-addressed
  /// (`store/SHA256/<hex>`) download URL.
  final String sha256;

  final Uri downloadUrl;
}

/// Parses the content hash out of a CIPD content-addressed storage URL
/// (`.../store/SHA256/<64 hex>?...`).
String cipdStoreSha256(Uri url) {
  final segments = url.pathSegments;
  final i = segments.indexOf('SHA256');
  if (i < 1 ||
      segments[i - 1] != 'store' ||
      i + 1 >= segments.length ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(segments[i + 1])) {
    throw FormatException('not a content-addressed CIPD URL: $url');
  }
  return segments[i + 1];
}

/// Checks that a CIPD instance id encodes [sha256Hex] (instance ids are
/// unpadded base64url of the digest followed by an algorithm suffix).
bool instanceIdMatches(String instanceId, String sha256Hex) {
  if (instanceId.length < 43) return false;
  try {
    final digest = base64Url.decode('${instanceId.substring(0, 43)}=');
    final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return hex == sha256Hex;
  } on FormatException {
    return false;
  }
}

/// Resolves [package]@[version] through the plain-HTTPS download endpoint
/// (`/dl/<package>/+/<version>`), which redirects to the content-addressed
/// zip without needing the cipd client.
Future<CipdInstance> resolveCipd(
  http.Client client,
  String package,
  String version,
) async {
  final url = Uri.parse('$cipdBackend/dl/$package/+/$version');
  for (var attempt = 1; ; attempt++) {
    try {
      final request = http.Request('GET', url)..followRedirects = false;
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 1));
      await response.stream.drain<void>();
      final location = response.headers['location'];
      final instanceId = response.headers['x-cipd-instance'];
      if (response.statusCode == 404) {
        throw StateError('CIPD has no $package@$version');
      }
      if (response.statusCode != 302 ||
          location == null ||
          instanceId == null) {
        throw HttpException(
          'unexpected CIPD response '
          '${response.statusCode}',
          uri: url,
        );
      }
      final target = url.resolve(location);
      final sha = cipdStoreSha256(target);
      if (!instanceIdMatches(instanceId, sha)) {
        throw StateError(
          'CIPD instance id $instanceId does not match '
          'storage hash $sha for $package@$version',
        );
      }
      return CipdInstance(
        package: package,
        version: version,
        instanceId: instanceId,
        sha256: sha,
        downloadUrl: target,
      );
    } on StateError {
      rethrow;
    } catch (e) {
      if (attempt >= 6) rethrow;
      log('resolve $package@$version failed ($e), retrying');
      await Future<void>.delayed(Duration(seconds: 2 * attempt * attempt));
    }
  }
}

/// Downloads (or reuses from [cacheDir]) the zip of [instance], verifying its
/// sha256 against the content address.
Future<File> fetchCipdZip(
  Net net,
  CipdInstance instance,
  Directory cacheDir,
) async {
  final file = File(p.join(cacheDir.path, 'cipd', '${instance.sha256}.zip'));
  if (file.existsSync()) {
    final actual = await sha256File(file);
    if (actual == instance.sha256) {
      log('cached ${instance.package}@${instance.version}');
      return file;
    }
    log('cached ${file.path} is corrupt, downloading again');
    file.deleteSync();
  }
  log('downloading ${instance.package}@${instance.version}');
  for (var attempt = 1; ; attempt++) {
    // The signed storage URL expires after a while, so re-resolve on retry
    // only through the stable /dl URL if this one fails.
    final digest = await net.download(instance.downloadUrl, file);
    if (digest.toString() == instance.sha256) return file;
    file.deleteSync();
    if (attempt >= 3) {
      throw StateError(
        'sha256 mismatch for ${instance.package}: got '
        '$digest, expected ${instance.sha256}',
      );
    }
    log('sha256 mismatch for ${instance.package}, retrying');
  }
}

/// Extracts a CIPD zip into [dest] (replacing it) and writes the
/// `.versions/<name>.cipd_version` stamp that Dart's GN reads.
Future<void> deployCipd({
  required File zip,
  required CipdInstance instance,
  required Directory dest,
  required String stampName,
}) async {
  final marker = File(p.join(dest.path, '.xgs_cipd'));
  final key = '${instance.package}@${instance.instanceId}';
  if (marker.existsSync() && marker.readAsStringSync() == key) {
    log('${dest.path} is up to date');
    return;
  }
  if (dest.existsSync()) dest.deleteSync(recursive: true);
  dest.createSync(recursive: true);
  log('extracting ${instance.package} into ${dest.path}');
  final input = InputFileStream(zip.path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final executables = extractEntries(
      archive,
      dest.path,
      skip: (name) => name.startsWith('.cipdpkg/'),
    );
    await makeExecutable(executables);
  } finally {
    await input.close();
  }
  final versions = Directory(p.join(dest.path, '.versions'))
    ..createSync(recursive: true);
  File(p.join(versions.path, '$stampName.cipd_version')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'package_name': instance.package,
      'instance_id': instance.instanceId,
    }),
  );
  marker.writeAsStringSync(key);
}

/// Extracts [archive] into [outputPath] and returns the files that carry an
/// executable bit (see [makeExecutable]). Symlinks are recreated on POSIX
/// hosts. On Windows (where creating symlinks needs privileges) a symlink to
/// a file of the same archive is materialized as a copy of that file.
List<String> extractEntries(
  Archive archive,
  String outputPath, {
  bool Function(String name)? skip,
}) {
  final root = p.canonicalize(outputPath);
  final executables = <String>[];
  final windowsLinks = <String, String>{};
  for (final entry in archive) {
    final name = entry.name;
    if (skip != null && skip(name)) continue;
    final target = p.normalize(p.join(root, name));
    if (target != root && !p.isWithin(root, target)) {
      throw StateError('archive entry escapes the destination: $name');
    }
    if (entry.isSymbolicLink) {
      if (Platform.isWindows) {
        windowsLinks[target] = p.normalize(
          p.join(p.dirname(target), entry.symbolicLink!),
        );
        continue;
      }
      final link = Link(target);
      if (link.existsSync()) link.deleteSync();
      link.createSync(entry.symbolicLink!, recursive: true);
      continue;
    }
    if (!entry.isFile) {
      Directory(target).createSync(recursive: true);
      continue;
    }
    File(target).parent.createSync(recursive: true);
    final output = OutputFileStream(target);
    entry.writeContent(output);
    output.closeSync();
    if ((entry.unixPermissions & 0x49) != 0) executables.add(target);
  }
  windowsLinks.forEach((link, target) {
    final source = File(target);
    if (p.isWithin(root, target) && source.existsSync()) {
      source.copySync(link);
    } else {
      log('skipping symlink $link -> $target');
    }
  });
  return executables;
}

/// Marks [files] executable (no-op on Windows).
Future<void> makeExecutable(List<String> files) async {
  if (Platform.isWindows) return;
  for (var i = 0; i < files.length; i += 200) {
    final chunk = files.sublist(
      i,
      i + 200 > files.length ? files.length : i + 200,
    );
    final result = await Process.run('chmod', ['755', ...chunk]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'chmod',
        chunk,
        '${result.stderr}',
        result.exitCode,
      );
    }
  }
}
