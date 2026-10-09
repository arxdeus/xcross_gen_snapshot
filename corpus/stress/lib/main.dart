// The stress corpus app (docs/CORPUS.md): everything runs from main with a
// seed only known at run time, so tree shaking and constant propagation
// keep every path in the snapshot.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'ffi.dart';
import 'generated.dart';
import 'language.dart';
import 'regexps.dart';

enum Planet implements Comparable<Planet> {
  mercury(3.303e+23, 2.4397e6),
  venus(4.869e+24, 6.0518e6),
  earth(5.976e+24, 6.37814e6),
  mars(6.421e+23, 3.3972e6),
  jupiter(1.9e+27, 7.1492e7),
  saturn(5.688e+26, 6.0268e7),
  uranus(8.686e+25, 2.5559e7),
  neptune(1.024e+26, 2.4746e7);

  const Planet(this.mass, this.radius);

  final double mass;
  final double radius;

  double get surfaceGravity => 6.67300E-11 * mass / (radius * radius);

  @override
  int compareTo(Planet other) => mass.compareTo(other.mass);
}

mixin Observable<T> {
  final _listeners = <void Function(T)>[];
  void listen(void Function(T) listener) => _listeners.add(listener);
  void emit(T value) {
    for (final l in List.of(_listeners)) {
      l(value);
    }
  }
}

mixin Disposable {
  bool _disposed = false;
  void dispose() => _disposed = true;
  bool get disposed => _disposed;
}

class Counter with Observable<int>, Disposable {
  late final String name = 'counter${_listeners.length}';
  int _value = 0;
  void increment([int by = 1]) => emit(_value += by);
}

String classify(String token) {
  switch (token) {
    case 'alpha' || 'beta' || 'gamma':
      return 'greek';
    case 'red' || 'green' || 'blue' || 'cyan' || 'magenta' || 'yellow':
      return 'color';
    case 'monday' || 'tuesday' || 'wednesday' || 'thursday' || 'friday':
      return 'weekday';
    case 'saturday' || 'sunday':
      return 'weekend';
    case final t when t.length > 12:
      return 'long';
    default:
      return 'word';
  }
}

int intSwitch(int v) => switch (v) {
  0 => 17,
  1 => 3,
  2 => 99,
  3 => -4,
  4 => 1000,
  5 => 5,
  6 => 66,
  7 => 0,
  8 => 12,
  9 => 31,
  10 => 7,
  11 => -1,
  12 => 42,
  13 => 64,
  14 => 128,
  15 => 255,
  >= 16 && < 32 => v * 2,
  < 0 => -v,
  _ => v ~/ 3,
};

Future<int> runIsolate(int seed) => Isolate.run(() {
  var x = seed;
  for (var i = 0; i < 1000; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
  }
  return x;
});

int runCollections(int seed) {
  var h = seed;
  void mix(Object? o) => h = (h * 31 + o.hashCode) & 0x3fffffff;
  final random = math.Random(seed);
  final values = List.generate(500, (_) => random.nextInt(1000));
  // Many ties: exercises the (stable vs unstable) sort behavior of the
  // Dart core library at run time.
  final sorted = [...values]..sort((a, b) => (a % 10).compareTo(b % 10));
  mix(sorted.take(20).join(','));
  mix(Planet.values.toList()..sort());
  mix(Planet.values.map((p) => p.surfaceGravity.toStringAsFixed(3)).join());
  mix(wordTable.length + wordTable.values.fold<int>(0, (a, b) => a ^ b));
  mix(doubleTable[seed % doubleTable.length]);
  mix(intSet.contains(seed));
  mix(recordTable[seed % recordTable.length]);
  mix(nested['k${seed % 60}']?.keys.toList());
  mix(shapes.map((s) => s.area(seed) + traitSum(s, seed)).reduce((a, b) => a ^ b));
  mix(shapes[seed % shapes.length].describe());
  mix(shapes.whereType<C17>().length);
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
    'values': values.take(10).toList(),
    'nested': {'a': [1, 2.5, null, true, 'x']},
  })));
  mix(base64Encode(bytes));
  mix(jsonDecode(utf8.decode(bytes)));
  final floats = Float64List(64);
  for (var i = 0; i < floats.length; i++) {
    floats[i] = math.sin(i * seed) * math.sqrt(i + 1);
  }
  mix(floats.reduce(math.max));
  final simd = Float32x4(1, 2, 3, seed.toDouble()) * Float32x4.splat(0.5);
  mix(simd.w + simd.shuffle(Float32x4.wzyx).x);
  mix(Int32x4(seed, 1, 2, 3).withX(7).signMask);
  mix(BigInt.from(seed).pow(20).toRadixString(36));
  mix([for (final t in ['alpha', 'red', 'sunday', 'internationalization', 'x']) classify(t)]);
  mix([for (var i = -3; i < 40; i++) intSwitch(i)]);
  final counter = Counter();
  var seen = 0;
  counter.listen((v) => seen += v);
  for (var i = 0; i < 5; i++) {
    counter.increment(i);
  }
  counter.dispose();
  mix(seen);
  mix(counter.name);
  mix(counter.disposed);
  return h;
}

const _sampleText = r'''
Order 2024-03-15: paid $42.50 for "Ωμέγα \"quoted\" text" by ALPHA user
Password1! and Straße, İstanbul, KELVIN sign K, σοφός, emoji 😀 and 𐍈.
begin
multi line block
end
international interview of the interior: abcd bce cd
mail: someone.else+tag@example.co.uk; 3 + 4; zzzyyyxxxwwwvvvuuutttsssrrrqqqpppooonnnmmmlllkkk
''';

Future<String> runAll(int seed) async {
  final results = <String, int>{
    'regexp': exerciseRegexps(_sampleText * (1 + seed % 3), seed),
    'language': await runLanguage(seed),
    'ffi': runFfi(seed),
    'collections': runCollections(seed),
    'isolate': await runIsolate(seed),
  };
  return results.entries.map((e) => '${e.key}=${e.value}').join('\n');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final seed = DateTime.now().microsecondsSinceEpoch & 0xffff;
  runApp(StressApp(results: runAll(seed)));
}

class StressApp extends StatelessWidget {
  const StressApp({super.key, required this.results});

  final Future<String> results;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('xcross corpus: stress')),
        body: FutureBuilder<String>(
          future: results,
          builder: (context, snapshot) => switch (snapshot) {
            AsyncSnapshot(hasError: true, :final error) => Text('error: $error'),
            AsyncSnapshot(hasData: true, :final data) => SelectableText(data!),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ),
    );
  }
}
