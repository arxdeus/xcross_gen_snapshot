import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'cipd.dart';
import 'config.dart';
import 'deps.dart';
import 'io.dart';

/// Git remote of the Dart SDK.
const dartSdkGitUrl = 'https://github.com/dart-lang/sdk.git';

/// Sparse-checkout patterns (non-cone) of the minimal Dart SDK tree that
/// `gn gen --root-target=//runtime/bin:gen_snapshot` needs (docs/RECIPE.md).
const sparsePatterns = [
  '/*',
  '!/*/',
  '/build/',
  '/runtime/',
  '/sdk/lib/',
  '/tools/*.py',
  '/tools/VERSION',
  '/utils/',
  '/third_party/double-conversion/',
  '/third_party/boringssl/',
  '/third_party/perfetto/',
];

/// DEPS-pinned git dependencies fetched as gitiles tarballs.
const gitDepPaths = [
  'third_party/zlib',
  'third_party/boringssl/src',
  'third_party/icu',
  'third_party/perfetto/src',
];

/// Third-party licenses shipped next to the binary: name -> path in the SDK.
Map<String, String> licenseSources(BuildMode mode) => {
  'dart-sdk': 'LICENSE',
  'zlib': 'third_party/zlib/LICENSE',
  'boringssl': 'third_party/boringssl/src/LICENSE',
  'icu': 'third_party/icu/LICENSE',
  'double-conversion': 'third_party/double-conversion/LICENSE',
  if (mode == BuildMode.profile) 'perfetto': 'third_party/perfetto/src/LICENSE',
};

/// Root of this package (where `patches/` and `licenses/` live).
Future<Directory> packageRoot() async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:xcross_gen_snapshot/xcross_gen_snapshot.dart'),
  );
  if (lib == null) throw StateError('cannot locate the package root');
  return Directory(p.dirname(p.dirname(lib.toFilePath())));
}

/// The pinned tool versions and dependency revisions read from Dart's DEPS.
class Pins {
  Pins._(
    this.deps,
    this.clang,
    this.gn,
    this.ninja,
    this.sysroot,
    this.gitDeps,
  );

  factory Pins.fromDeps(DartDeps deps, Host host) {
    final clangPath = switch (host) {
      Host.linuxX64 => 'buildtools/linux-x64/clang',
      Host.linuxArm64 => 'buildtools/linux-arm64/clang',
      Host.windowsX64 || Host.windowsArm64 => 'buildtools/win-x64/clang',
    };
    final clang = deps.cipdDep(clangPath);
    final gn = deps.cipdDep(host.isWindows ? 'buildtools/win' : 'buildtools');
    final ninja = deps.cipdDep('buildtools/ninja');
    final sysroot = host.isWindows
        ? null
        : deps.cipdDep('buildtools/sysroot/linux');
    return Pins._(
      deps,
      PinnedTool('clang', clang.package, clang.version, host.clangDir),
      PinnedTool(
        'gn',
        gn.packageFor(host.toolCipdPlatform),
        gn.version,
        'buildtools/xgs-gn',
      ),
      PinnedTool(
        'ninja',
        ninja.packageFor(host.cipdPlatform),
        ninja.version,
        'buildtools/ninja',
      ),
      sysroot == null
          ? null
          : PinnedTool(
              'sysroot',
              sysroot.package,
              sysroot.version,
              'buildtools/sysroot/linux',
            ),
      [for (final path in gitDepPaths) deps.gitDep(path)],
    );
  }

  final DartDeps deps;
  final PinnedTool clang;
  final PinnedTool gn;
  final PinnedTool ninja;
  final PinnedTool? sysroot;
  final List<GitDep> gitDeps;

  List<PinnedTool> get tools => [clang, gn, ninja, ?sysroot];

  /// Stable description used as a cache key.
  Map<String, String> describe() => {
    for (final t in tools) t.stamp: '${t.package}@${t.version}',
    for (final d in gitDeps) d.path: d.revision,
  };
}

/// A CIPD tool pinned by DEPS and where it is deployed in the tree.
class PinnedTool {
  const PinnedTool(this.stamp, this.package, this.version, this.dest);

  final String stamp;
  final String package;
  final String version;
  final String dest;
}

/// A prepared Dart SDK tree, ready for `gn gen`.
class SourceTree {
  SourceTree(this.root, this.pins);

  final Directory root;
  final Pins pins;

  String path(String relative) => p.join(root.path, relative);
}

/// Fetches the Dart SDK at [dartRevision] plus deps and tools into
/// `<workDir>/sdk`, applies the patches and generates the version file.
Future<SourceTree> prepareSource({
  required Net net,
  required http.Client client,
  required Directory workDir,
  required Directory cacheDir,
  required String dartRevision,
  required Host host,
  required String python,
  bool trustCachedGitDeps = true,
}) async {
  final pkg = await packageRoot();
  final patches = [
    File(p.join(pkg.path, 'patches', 'dart_sdk.patch')),
    if (host.isWindows) File(p.join(pkg.path, 'patches', 'windows_host.patch')),
  ].where((f) => f.existsSync()).toList();
  final patchKey = [
    for (final f in patches) sha256Bytes(f.readAsBytesSync()),
  ].join(',');

  final sdk = Directory(p.join(workDir.path, 'sdk'));
  final marker = File(p.join(sdk.path, '.xgs_source'));
  final key = '$dartRevision ${host.id} $patchKey';
  if (marker.existsSync() && marker.readAsStringSync() == key) {
    log('reusing prepared source tree ${sdk.path}');
    final deps = DartDeps.parse(
      File(p.join(sdk.path, 'DEPS')).readAsStringSync(),
    );
    return SourceTree(sdk, Pins.fromDeps(deps, host));
  }
  if (sdk.existsSync()) {
    log('removing stale source tree ${sdk.path}');
    sdk.deleteSync(recursive: true);
  }
  sdk.createSync(recursive: true);

  // 1. Sparse, shallow, blobless checkout of the Dart SDK at the revision.
  await _checkoutDart(sdk, dartRevision);

  // 2. Pins from that revision's DEPS.
  final deps = DartDeps.parse(
    File(p.join(sdk.path, 'DEPS')).readAsStringSync(),
  );
  final pins = Pins.fromDeps(deps, host);
  log('pins: ${const JsonEncoder.withIndent('  ').convert(pins.describe())}');

  // 3. Git deps from gitiles tarballs.
  for (final dep in pins.gitDeps) {
    await fetchGitDep(net, dep, sdk, cacheDir, trustCache: trustCachedGitDeps);
  }

  // 4. Tools from CIPD.
  for (final tool in pins.tools) {
    final instance = await resolveCipd(client, tool.package, tool.version);
    final zip = await fetchCipdZip(net, instance, cacheDir);
    await deployCipd(
      zip: zip,
      instance: instance,
      dest: Directory(p.join(sdk.path, tool.dest)),
      stampName: tool.stamp,
    );
  }

  // 5. Files gclient would normally generate.
  File(
    p.join(sdk.path, 'build', 'config', 'gclient_args.gni'),
  ).writeAsStringSync(
    '# Generated by xcross_gen_snapshot\n'
    'build_devtools_from_sources = false\n',
  );
  await run(python, [
    'tools/generate_sdk_version_file.py',
  ], workingDirectory: sdk.path);

  // 6. Patches.
  for (final patch in patches) {
    await run('git', [
      'apply',
      '--verbose',
      patch.absolute.path,
    ], workingDirectory: sdk.path);
  }

  marker.writeAsStringSync(key);
  return SourceTree(sdk, pins);
}

Future<void> _checkoutDart(Directory sdk, String revision) async {
  Future<void> git(List<String> args) =>
      run('git', args, workingDirectory: sdk.path);
  await git(['init', '-q']);
  // Windows runners default to core.autocrlf=true, which would change the
  // bytes of sources that Dart hashes into the snapshot version.
  await git(['config', 'core.autocrlf', 'false']);
  await git(['config', 'core.eol', 'lf']);
  await git(['config', 'core.sparseCheckout', 'true']);
  await git(['config', 'advice.detachedHead', 'false']);
  await git(['remote', 'add', 'origin', dartSdkGitUrl]);
  File(p.join(sdk.path, '.git', 'info', 'sparse-checkout'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${sparsePatterns.join('\n')}\n');
  for (var attempt = 1; ; attempt++) {
    try {
      await git([
        'fetch',
        '--depth',
        '1',
        '--filter=blob:none',
        '--no-tags',
        'origin',
        revision,
      ]);
      await git(['checkout', '-q', '--detach', 'FETCH_HEAD']);
      break;
    } on ProcessException {
      if (attempt >= 4) rethrow;
      log('git fetch/checkout failed, retrying');
      await Future<void>.delayed(Duration(seconds: 10 * attempt));
    }
  }
  final head = await capture('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: sdk.path);
  if (head != revision) {
    throw StateError('checked out $head, expected $revision');
  }
}

/// Fetches the gitiles tarball of [dep] and extracts it into the tree.
///
/// gitiles tarballs are not byte-stable, so a cached one is only known by
/// its file name. With [trustCache] false (publishing builds) a cached
/// tarball is ignored and the dependency is downloaded again from
/// googlesource.
Future<void> fetchGitDep(
  Net net,
  GitDep dep,
  Directory sdk,
  Directory cacheDir, {
  required bool trustCache,
}) async {
  final name = dep.path.replaceAll('/', '_');
  final tarball = File(
    p.join(cacheDir.path, 'git', '$name-${dep.revision}.tar.gz'),
  );
  if (!trustCache && tarball.existsSync()) {
    log('ignoring cached $dep (cached git deps are not trusted)');
    tarball.deleteSync();
  }
  if (!tarball.existsSync()) {
    log('downloading $dep');
    await net.download(dep.archiveUrl, tarball);
  } else {
    log('cached $dep');
  }
  final dest = Directory(p.join(sdk.path, dep.path));
  dest.createSync(recursive: true);
  final tmp = File('${tarball.path}.tar');
  try {
    final input = InputFileStream(tarball.path);
    final output = OutputFileStream(tmp.path);
    GZipDecoder().decodeStream(input, output);
    await input.close();
    await output.close();
    final tarInput = InputFileStream(tmp.path);
    try {
      final archive = TarDecoder().decodeStream(tarInput);
      if (archive.isEmpty) throw StateError('empty archive for $dep');
      final executables = extractEntries(archive, dest.path);
      await makeExecutable(executables);
    } finally {
      await tarInput.close();
    }
  } catch (e) {
    // A truncated cached tarball must not poison later runs.
    if (tarball.existsSync()) tarball.deleteSync();
    rethrow;
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}
