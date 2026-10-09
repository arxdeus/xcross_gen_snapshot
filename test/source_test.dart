import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

List<int> tarGz(String name, String content) {
  final archive = Archive()..addFile(ArchiveFile.string(name, content));
  return GZipEncoder().encode(TarEncoder().encode(archive));
}

void main() {
  late HttpServer server;
  late Directory dir;
  var requests = 0;

  setUp(() async {
    requests = 0;
    dir = Directory.systemTemp.createTempSync('xgs_gitdep');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      request.response
        ..add(tarGz('README', 'from upstream'))
        ..close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Future<String> fetch({required bool trustCache}) async {
    final dep = GitDep(
      path: 'third_party/zlib',
      url: 'http://${server.address.host}:${server.port}/zlib.git',
      revision: 'abc123',
    );
    final cache = Directory(p.join(dir.path, 'cache'));
    // A poisoned cache entry under the exact file name the build looks for.
    File(p.join(cache.path, 'git', 'third_party_zlib-abc123.tar.gz'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(tarGz('README', 'poisoned'));
    final sdk = Directory(p.join(dir.path, 'sdk'))..createSync();
    final net = Net();
    try {
      await fetchGitDep(net, dep, sdk, cache, trustCache: trustCache);
    } finally {
      net.close();
    }
    return File(p.join(sdk.path, 'third_party/zlib/README')).readAsStringSync();
  }

  test('publishing builds ignore cached git dep tarballs', () async {
    expect(await fetch(trustCache: false), 'from upstream');
    expect(requests, 1);
  });

  test('verification builds reuse the cached tarball', () async {
    expect(await fetch(trustCache: true), 'poisoned');
    expect(requests, 0);
  });
}
