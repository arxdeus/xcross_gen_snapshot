import 'package:test/test.dart';
import 'package:xcross_gen_snapshot/xcross_gen_snapshot.dart';

void main() {
  const sha =
      '90c02d2244951bd3e11626d34e5e86281b338a2fffcfddf7c0efa491a001685f';

  test('content hash from the storage URL', () {
    expect(
      cipdStoreSha256(
        Uri.parse(
          'https://storage.googleapis.com/'
          'chrome-infra-packages/store/SHA256/$sha?X-Goog-Algorithm=x',
        ),
      ),
      sha,
    );
    expect(
      () => cipdStoreSha256(Uri.parse('https://example.com/x.zip')),
      throwsFormatException,
    );
  });

  test('instance id encodes the hash (gn/gn/linux-arm64)', () {
    expect(
      instanceIdMatches('kMAtIkSVG9PhFibTTl6GKBszii__z933wO-kkaABaF8C', sha),
      isTrue,
    );
    expect(
      instanceIdMatches(
        'kMAtIkSVG9PhFibTTl6GKBszii__z933wO-kkaABaF8C',
        sha.replaceFirst('9', '8'),
      ),
      isFalse,
    );
    expect(instanceIdMatches('short', sha), isFalse);
  });
}
