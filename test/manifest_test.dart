import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

void main() {
  const release = FlutterRelease(
    flutter: '3.47.0',
    engine: '5f77625673248ee5846fbcaf5d3e1a3878386fd7',
    dart: 'da6595cd6bb5d4c0a185d759a025e879ff06e631',
  );
  String h(String c) => c * 64;

  test('asset names', () {
    expect(
      assetName(BuildMode.release, Host.linuxX64),
      'gen_snapshot-release-linux-x64.zip',
    );
    expect(allAssetNames(), hasLength(8));
    expect(allAssetNames(), contains('gen_snapshot-profile-windows-arm64.zip'));
  });

  test('zip is deterministic, keeps the exec bit and is inspectable', () {
    final entries = [
      ZipEntry('licenses/LICENSE.zlib', utf8.encode('zlib license')),
      ZipEntry(
        'gen_snapshot',
        List.generate(5000, (i) => i % 7),
        executable: true,
      ),
    ];
    final a = encodeZip(entries);
    final b = encodeZip(entries.reversed.toList());
    expect(a, b);
    final archive = ZipDecoder().decodeBytes(a);
    final exe = archive.findFile('gen_snapshot')!;
    expect(exe.readBytes(), List.generate(5000, (i) => i % 7));
    expect(exe.unixPermissions, 0x1ed);
    expect(archive.findFile('licenses/LICENSE.zlib')!.unixPermissions, 0x1a4);
    final info = AssetInfo.inspect(a, Host.linuxX64);
    expect(info.size, a.length);
    expect(
      info.executableSha256,
      sha256Bytes(List.generate(5000, (i) => i % 7)),
    );
    expect(() => AssetInfo.inspect(a, Host.windowsX64), throwsStateError);
  });

  test('system unzip extracts it with the exec bit', () async {
    final unzip = await Process.run('which', ['unzip']);
    if (unzip.exitCode != 0) return;
    final dir = Directory.systemTemp.createTempSync('xgs_zip');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/a.zip').writeAsBytesSync(
      encodeZip([
        ZipEntry(
          'gen_snapshot',
          utf8.encode('#!/bin/sh\necho ok\n'),
          executable: true,
        ),
        ZipEntry('licenses/LICENSE.dart-sdk', utf8.encode('x')),
      ]),
    );
    final r = await Process.run('unzip', [
      '-q',
      'a.zip',
    ], workingDirectory: dir.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final run = await Process.run(
      './gen_snapshot',
      [],
      workingDirectory: dir.path,
    );
    expect('${run.stdout}'.trim(), 'ok');
  });

  test('manifest follows the contract', () {
    final assets = {
      for (final n in allAssetNames())
        n: AssetInfo(sha256: h('a'), executableSha256: h('b'), size: 42),
    };
    final manifest = buildManifest(
      release: release,
      patchSha256: h('c'),
      assets: assets,
      releaseAppSha256: h('d'),
      profileAppSha256: h('e'),
    );
    expect(manifest['schema'], 1);
    expect(manifest['flutter'], '3.47.0');
    expect(manifest['engine'], release.engine);
    expect(manifest['dart'], release.dart);
    expect(manifest['patch_sha256'], h('c'));
    final a = manifest['assets'] as Map;
    expect(a.keys, allAssetNames()..sort());
    expect(a['gen_snapshot-release-linux-x64.zip'], {
      'sha256': h('a'),
      'executable_sha256': h('b'),
      'size': 42,
    });
    expect(manifest['verification'], {
      'reference_app': 'flutter create default app',
      'release_app_sha256': h('d'),
      'profile_app_sha256': h('e'),
    });
    // Canonical text round-trips.
    expect(jsonDecode(encodeManifest(manifest)), manifest);
  });

  test('manifest rejects incomplete asset sets', () {
    expect(
      () => buildManifest(
        release: release,
        patchSha256: h('c'),
        assets: {
          'gen_snapshot-release-linux-x64.zip': AssetInfo(
            sha256: h('a'),
            executableSha256: h('b'),
            size: 1,
          ),
        },
        releaseAppSha256: h('d'),
        profileAppSha256: h('e'),
      ),
      throwsStateError,
    );
  });
}
