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
  });

  test('rejects changed flags', () {
    const line =
        '[  ] executing: /x/gen_snapshot_arm64 --deterministic '
        '--snapshot_kind=app-aot-macho-dylib --macho=/a/App '
        '--macho-object=/a/app.o --macho-min-os-version=16.0 '
        '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks '
        '--macho-install-name=@rpath/App.framework/App /a/app.dill';
    expect(() => parseFlutterBuildLog(line), throwsStateError);
    expect(
      parseFlutterBuildLog(line.replaceFirst('16.0', '15.0')).dill,
      '/a/app.dill',
    );
    expect(() => parseFlutterBuildLog('$line\n$line'), throwsStateError);
  });
}
