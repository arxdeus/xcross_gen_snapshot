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

  test('verifications must cover every published executable', () {
    final manifest = buildManifest(
      release: release,
      patchSha256: h('c'),
      assets: {
        for (final n in allAssetNames())
          n: AssetInfo(sha256: h('a'), executableSha256: h('b'), size: 42),
      },
      releaseAppSha256: h('d'),
      profileAppSha256: h('e'),
    );
    Map<String, Map<String, Object?>> results({
      String compiler = 'b',
      String? only,
    }) => {
      for (final mode in BuildMode.values)
        for (final host in Host.values)
          assetName(mode, host): {
            'compiler_sha256': h(
              only == null || only == assetName(mode, host) ? compiler : 'b',
            ),
            'app_sha256': h(mode == BuildMode.release ? 'd' : 'e'),
          },
    };
    checkVerifications(manifest, results());
    expect(
      () => checkVerifications(
        manifest,
        results(compiler: 'f', only: 'gen_snapshot-profile-windows-arm64.zip'),
      ),
      throwsStateError,
    );
    final wrongApp = results();
    wrongApp['gen_snapshot-release-linux-x64.zip']!['app_sha256'] = h('e');
    expect(() => checkVerifications(manifest, wrongApp), throwsStateError);
    final missing = results()..remove('gen_snapshot-release-linux-arm64.zip');
    expect(() => checkVerifications(manifest, missing), throwsStateError);
  });

  test('windows toolchain versions from an environment block', () {
    final block = [
      r'INCLUDE=C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.44.35207\include;'
          r'C:\Program Files (x86)\Windows Kits\10\include\10.0.26100.0\ucrt',
      r'LIB=C:\Program Files (x86)\Windows Kits\10\lib\10.0.26100.0\ucrt\x64',
      r'PATH=C:\Windows',
      '',
    ].join('\u0000');
    expect(parseWindowsEnvironmentBlock(block), {
      'msvc_tools_version': '14.44.35207',
      'windows_sdk_version': '10.0.26100.0',
    });
    expect(parseWindowsEnvironmentBlock('PATH=x\u0000\u0000'), {
      'msvc_tools_version': null,
      'windows_sdk_version': null,
    });
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
  test('a downloaded asset is checked against the published manifest', () {
    final assets = {
      for (final n in allAssetNames())
        n: AssetInfo(sha256: h('a'), executableSha256: h('b'), size: 42),
    };
    final manifest =
        jsonDecode(
              encodeManifest(
                buildManifest(
                  release: release,
                  patchSha256: h('c'),
                  assets: assets,
                  releaseAppSha256: h('d'),
                  profileAppSha256: h('e'),
                ),
              ),
            )
            as Map<String, Object?>;
    const name = 'gen_snapshot-profile-windows-arm64.zip';
    final good = AssetInfo(sha256: h('a'), executableSha256: h('b'), size: 42);
    checkAssetAgainstManifest(manifest, asset: name, info: good);
    checkAssetAgainstManifest(
      manifest,
      asset: name,
      info: good,
      flutter: '3.47.0',
    );
    void rejects(AssetInfo info, {String asset = name, String? flutter}) =>
        expect(
          () => checkAssetAgainstManifest(
            manifest,
            asset: asset,
            info: info,
            flutter: flutter,
          ),
          throwsStateError,
        );
    rejects(AssetInfo(sha256: h('f'), executableSha256: h('b'), size: 42));
    rejects(AssetInfo(sha256: h('a'), executableSha256: h('f'), size: 42));
    rejects(AssetInfo(sha256: h('a'), executableSha256: h('b'), size: 43));
    rejects(good, asset: 'gen_snapshot-debug-linux-x64.zip');
    rejects(good, flutter: '3.47.1');
    expect(
      () => checkAssetAgainstManifest(
        {...manifest, 'schema': 2},
        asset: name,
        info: good,
      ),
      throwsStateError,
    );
  });
}
