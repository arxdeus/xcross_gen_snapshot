import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('parseDeps', () {
    test('evaluates the python literal subset', () {
      final top = parseDeps('''
# comment
vars = {
  "a": "x",  # trailing comment
  'b': Var("a") + "/y" "z",
  "flag": True,
  "n": 3,
}
deps = {
  Var("a") + "/dep": {
    "url": Var("b") + "@" + "rev",
    "condition": "host_os == 'linux'",
  },
  'list': [1, 2,],
  'builtin': Var('host_os'),
}
''');
      final vars = top['vars'] as Map;
      expect(vars['b'], 'x/yz');
      expect(vars['flag'], isTrue);
      expect(vars['n'], 3);
      final deps = top['deps'] as Map;
      expect((deps['x/dep'] as Map)['url'], 'x/yz@rev');
      expect(deps['list'], [1, 2]);
      expect(deps['builtin'], '{host_os}');
    });

    test('rejects unsupported syntax', () {
      expect(() => parseDeps('x = foo(1)'), throwsA(isA<DepsException>()));
      expect(
        () => parseDeps('x = "unterminated'),
        throwsA(isA<DepsException>()),
      );
    });
  });

  group('Dart SDK DEPS (da6595cd)', () {
    final deps = DartDeps.parse(fixture('dart_DEPS_da6595cd'));

    test('git deps', () {
      final zlib = deps.gitDep('third_party/zlib');
      expect(
        zlib.url,
        'https://chromium.googlesource.com/chromium/src/third_party/zlib.git',
      );
      expect(zlib.revision, '3008c4b3a06bd65392c31db8846000a21e3d03c5');
      expect(
        zlib.archiveUrl.toString(),
        'https://chromium.googlesource.com/chromium/src/third_party/zlib.git'
        '/+archive/3008c4b3a06bd65392c31db8846000a21e3d03c5.tar.gz',
      );
      expect(
        deps.gitDep('third_party/boringssl/src').revision,
        '2e508c973d634b3aa51b71db5062bc6b096e5031',
      );
      expect(
        deps.gitDep('third_party/icu').url,
        'https://chromium.googlesource.com/chromium/deps/icu.git',
      );
      expect(
        deps.gitDep('third_party/perfetto/src').revision,
        '13ce0c9e13b0940d2476cd0cff2301708a9a2e2b',
      );
    });

    test('cipd deps', () {
      const clang = 'git_revision:deb6854eec93529b2bd30178d400ad2ee7665cd4';
      final linux = deps.cipdDep('buildtools/linux-x64/clang');
      expect(linux.package, 'fuchsia/third_party/clang/linux-amd64');
      expect(linux.version, clang);
      expect(
        deps.cipdDep('buildtools/win-x64/clang').package,
        'fuchsia/third_party/clang/windows-amd64',
      );
      final ninja = deps.cipdDep('buildtools/ninja');
      expect(
        ninja.packageFor('linux-arm64'),
        'infra/3pp/tools/ninja/linux-arm64',
      );
      expect(ninja.version, 'version:3@1.13.2.chromium.4');
      expect(
        deps.cipdDep('buildtools').packageFor('linux-amd64'),
        'gn/gn/linux-amd64',
      );
      expect(deps.cipdDep('buildtools/win').package, 'gn/gn/windows-amd64');
      expect(
        deps.cipdDep('buildtools/sysroot/linux').version,
        'git_revision:fa7a5a9710540f30ff98ae48b62f2cdf72ed2acd',
      );
    });

    test('pins per host', () {
      final arm = Pins.fromDeps(deps, Host.windowsArm64).describe();
      expect(
        arm['clang'],
        startsWith('fuchsia/third_party/clang/windows-amd64@'),
      );
      expect(arm['gn'], startsWith('gn/gn/windows-amd64@'));
      expect(arm['ninja'], startsWith('infra/3pp/tools/ninja/windows-arm64@'));
      expect(arm.containsKey('sysroot'), isFalse);
      final linux = Pins.fromDeps(deps, Host.linuxArm64).describe();
      expect(
        linux['clang'],
        startsWith('fuchsia/third_party/clang/linux-arm64@'),
      );
      expect(
        linux['sysroot'],
        startsWith('fuchsia/third_party/sysroot/linux@'),
      );
    });

    test('missing entries throw', () {
      expect(
        () => deps.gitDep('third_party/nope'),
        throwsA(isA<DepsException>()),
      );
      expect(
        () => deps.cipdDep('third_party/zlib'),
        throwsA(isA<DepsException>()),
      );
    });
  });

  test('Flutter DEPS dart_revision', () {
    expect(
      dartRevisionFromFlutterDeps(fixture('flutter_DEPS_3.47.0')),
      'da6595cd6bb5d4c0a185d759a025e879ff06e631',
    );
  });
}
