import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

void main() {
  test('parses the gen_snapshot call of flutter build ios -v (3.47.0)', () {
    final log = File(
      'test/fixtures/flutter_build_ios_release_3.47.0.log',
    ).readAsStringSync();
    final invocation = parseFlutterBuildLog(log);
    expect(
      invocation.compiler,
      endsWith('/artifacts/engine/ios-release/gen_snapshot_arm64'),
    );
    expect(invocation.dill, endsWith('/app.dill'));
    expect(invocation.minOsVersion, '15.0');
  });

  const line =
      '[  ] executing: /x/gen_snapshot_arm64 --deterministic '
      '--snapshot_kind=app-aot-macho-dylib --macho=/a/App '
      '--macho-object=/a/app.o --macho-min-os-version=13.0 '
      '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks '
      '--macho-install-name=@rpath/App.framework/App /a/app.dill';

  test('takes the min OS version from the log (Flutter 3.44 uses 13.0)', () {
    final invocation = parseFlutterBuildLog(line);
    expect(invocation.dill, '/a/app.dill');
    expect(invocation.minOsVersion, '13.0');
    expect(
      parseFlutterBuildLog(line.replaceFirst('13.0', '16.0')).minOsVersion,
      '16.0',
    );
  });

  test('rejects changed flags', () {
    expect(
      () => parseFlutterBuildLog(line.replaceFirst('--deterministic ', '')),
      throwsStateError,
    );
    expect(
      () => parseFlutterBuildLog(
        line.replaceFirst(' /a/app.dill', ' -x /a/app.dill'),
      ),
      throwsStateError,
    );
    expect(
      () => parseFlutterBuildLog(
        line.replaceFirst(
          '--macho-min-os-version=13.0',
          '--macho-min-os-version=x',
        ),
      ),
      throwsStateError,
    );
    expect(
      () => parseFlutterBuildLog(
        line.replaceFirst(
          '--macho-min-os-version=13.0',
          '--macho-min-os-version=13.0 --macho-min-os-version=14.0',
        ),
      ),
      throwsStateError,
    );
    expect(() => parseFlutterBuildLog('$line\n$line'), throwsStateError);
  });

  test('verification flags carry the min OS version', () {
    expect(verificationFlags(), contains('--macho-min-os-version=15.0'));
    expect(
      verificationFlags(minOsVersion: '13.0'),
      contains('--macho-min-os-version=13.0'),
    );
    expect(() => verificationFlags(minOsVersion: '13 '), throwsArgumentError);
  });

  test('reference results record the min OS version', () {
    final result = SnapshotResult(
      appSha256: 'a',
      appSize: 1,
      objectSha256: null,
      minOsVersion: '13.0',
    );
    expect(SnapshotResult.fromJson(result.toJson()).minOsVersion, '13.0');
    // Results written before it was recorded were made with 15.0.
    expect(
      SnapshotResult.fromJson({'app_sha256': 'a', 'app_size': 1}).minOsVersion,
      '15.0',
    );
  });
}
