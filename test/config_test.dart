import 'package:test/test.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

const dart = 'da6595cd6bb5d4c0a185d759a025e879ff06e631';

Map<String, String> parse(String argsGn) => {
  for (final line in argsGn.trim().split('\n'))
    line.split(' = ')[0]: line.split(' = ')[1],
};

void main() {
  test('release args for linux arm64 match the verified lab build', () {
    final args = parse(
      renderArgsGn(
        host: Host.linuxArm64,
        mode: BuildMode.release,
        dartRevision: dart,
      ),
    );
    expect(args, {
      'target_os': '"linux"',
      'target_cpu': '"arm64"',
      'host_cpu': '"arm64"',
      'dart_target_arch': '"arm64"',
      'dart_use_compressed_pointers': 'false',
      'is_debug': 'false',
      'dart_debug': 'false',
      'is_release': 'false',
      'is_product': 'true',
      'dart_runtime_mode': '"release"',
      'dart_default_optimization_level': '"2"',
      'dart_component_kind': '"static_library"',
      'dart_lib_export_symbols': 'false',
      'dart_version_git_info': 'true',
      'verify_sdk_hash': 'true',
      'dart_sdk_verification_hash': '"da6595cd6b"',
      'exclude_kernel_service': 'false',
      'is_clang': 'true',
      'dart_vm_code_coverage': 'false',
      'dart_dynamic_modules': 'false',
      'dart_sysroot': '"debian"',
      'dart_xcross_target_os_ios': 'true',
    });
  });

  test('profile flips product/release', () {
    final args = parse(
      renderArgsGn(
        host: Host.linuxX64,
        mode: BuildMode.profile,
        dartRevision: dart,
      ),
    );
    expect(args['is_product'], 'false');
    expect(args['is_release'], 'true');
    expect(args['dart_runtime_mode'], '"profile"');
    expect(args['target_cpu'], '"x64"');
  });

  test('windows uses target_os win and no sysroot', () {
    final args = parse(
      renderArgsGn(
        host: Host.windowsArm64,
        mode: BuildMode.release,
        dartRevision: dart,
      ),
    );
    expect(args['target_os'], '"win"');
    expect(args['target_cpu'], '"arm64"');
    expect(args['host_cpu'], '"arm64"');
    expect(args.containsKey('dart_sysroot'), isFalse);
  });

  test('rejects a short revision', () {
    expect(
      () => renderArgsGn(
        host: Host.linuxX64,
        mode: BuildMode.release,
        dartRevision: 'abc',
      ),
      throwsArgumentError,
    );
  });

  test('hosts', () {
    expect(Host.parse('windows-arm64').toolCipdPlatform, 'windows-amd64');
    expect(Host.windowsArm64.cipdPlatform, 'windows-arm64');
    expect(Host.windowsArm64.clangDir, 'buildtools/win-x64/clang');
    expect(Host.linuxX64.executableName, 'gen_snapshot');
    expect(Host.windowsX64.executableName, 'gen_snapshot.exe');
  });
}
