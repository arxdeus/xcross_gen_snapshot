import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('xgs_corpus_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String relative, String content) =>
      File(p.join(tmp.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);

  test('finds the sample libraries that declare main, sorted', () {
    write('lib/widgets/b/b.0.dart', 'void main() => runApp(const B());\n');
    write('lib/material/a/a.1.dart', 'import "x";\n\nvoid main() {\n}\n');
    write('lib/material/a/a.0.dart', 'Future<void> main() async {}\n');
    write('lib/material/a/helper.dart', 'class Helper {}\n// void main()\n');
    write('lib/material/a/notes.txt', 'void main() {}\n');
    expect(findSampleLibraries(Directory(p.join(tmp.path, 'lib'))), [
      'material/a/a.0.dart',
      'material/a/a.1.dart',
      'widgets/b/b.0.dart',
    ]);
  });

  test('the samples entrypoint keeps every sample main reachable', () {
    final source = renderSamplesEntrypoint(['a/x.0.dart', 'b/y.1.dart']);
    expect(source, contains("import 'samples/a/x.0.dart' as s0;"));
    expect(source, contains("import 'samples/b/y.1.dart' as s1;"));
    expect(source, contains('  s0.main,\n  s1.main,\n'));
    expect(source, contains("  'a/x.0.dart',\n  'b/y.1.dart',\n"));
    expect(source, contains('void main() {'));
    expect(() => renderSamplesEntrypoint([]), throwsArgumentError);
  });

  test('writeSamplesApp copies the samples and writes main.dart', () {
    write('flutter/lib/m/a.0.dart', 'void main() {}\n');
    write('flutter/lib/m/util.dart', 'int util() => 1;\n');
    write('app/lib/main.dart', 'old template');
    write('app/lib/stale.dart', 'old');
    final count = writeSamplesApp(
      samplesLib: Directory(p.join(tmp.path, 'flutter', 'lib')),
      app: Directory(p.join(tmp.path, 'app')),
    );
    expect(count, 1);
    final lib = p.join(tmp.path, 'app', 'lib');
    expect(File(p.join(lib, 'samples', 'm', 'a.0.dart')).existsSync(), isTrue);
    expect(File(p.join(lib, 'stale.dart')).existsSync(), isFalse);
    expect(
      File(p.join(lib, 'main.dart')).readAsStringSync(),
      contains("import 'samples/m/a.0.dart' as s0;"),
    );
  });

  test('corpus/stress/lib/generated.dart is up to date', () {
    // Regenerate with:
    //   dart run xcross_gen_snapshot:corpus \
    //     --stress-generated corpus/stress/lib/generated.dart
    expect(
      File('corpus/stress/lib/generated.dart').readAsStringSync(),
      renderStressGenerated(),
    );
  });

  test('the generated stress code is deterministic and large', () {
    final a = renderStressGenerated();
    expect(renderStressGenerated(), a);
    expect(
      RegExp(r'^(base|final) class C\d+ ', multiLine: true).allMatches(a),
      hasLength(240),
    );
    expect(a, contains('const wordTable = <String, int>{'));
  });

  test('every corpus app directory has a lib/main.dart', () {
    for (final app in corpusApps) {
      if (app == defaultApp || app == apiSamplesApp) continue;
      expect(
        File('corpus/$app/lib/main.dart').existsSync(),
        isTrue,
        reason: app,
      );
    }
  });
}
