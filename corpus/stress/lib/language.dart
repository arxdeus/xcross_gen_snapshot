// Language features that stress the AOT compiler: records and patterns,
// sealed hierarchies with exhaustive switches, async*/sync* generators,
// extension types, generics, closures and try/catch/finally nesting.

import 'dart:async';
import 'dart:collection';

sealed class Expr {
  const Expr();
}

final class Num extends Expr {
  const Num(this.value);
  final num value;
}

final class Var extends Expr {
  const Var(this.name);
  final String name;
}

final class Add extends Expr {
  const Add(this.left, this.right);
  final Expr left;
  final Expr right;
}

final class Mul extends Expr {
  const Mul(this.left, this.right);
  final Expr left;
  final Expr right;
}

final class Neg extends Expr {
  const Neg(this.operand);
  final Expr operand;
}

final class Let extends Expr {
  const Let(this.name, this.value, this.body);
  final String name;
  final Expr value;
  final Expr body;
}

final class Call extends Expr {
  const Call(this.function, this.arguments);
  final String function;
  final List<Expr> arguments;
}

num evaluate(Expr e, Map<String, num> env) => switch (e) {
  Num(:final value) => value,
  Var(:final name) => env[name] ?? (throw StateError('unbound $name')),
  Add(left: Num(value: 0), :final right) => evaluate(right, env),
  Add(:final left, right: Num(value: 0)) => evaluate(left, env),
  Add(:final left, :final right) => evaluate(left, env) + evaluate(right, env),
  Mul(left: Num(value: 0)) || Mul(right: Num(value: 0)) => 0,
  Mul(:final left, :final right) => evaluate(left, env) * evaluate(right, env),
  Neg(operand: Neg(:final operand)) => evaluate(operand, env),
  Neg(:final operand) => -evaluate(operand, env),
  Let(:final name, :final value, :final body) => evaluate(body, {
    ...env,
    name: evaluate(value, env),
  }),
  Call(function: 'max', arguments: [final a, final b]) => _max(
    evaluate(a, env),
    evaluate(b, env),
  ),
  Call(function: 'sum', :final arguments) => arguments.fold<num>(
    0,
    (acc, a) => acc + evaluate(a, env),
  ),
  Call(:final function, arguments: []) => function.length,
  Call(:final function, :final arguments) => throw ArgumentError(
    '$function/${arguments.length}',
  ),
};

num _max(num a, num b) => a > b ? a : b;

String describe(Object? value) => switch (value) {
  null => 'null',
  int n when n < 0 => 'negative int $n',
  int(isEven: true) => 'even int',
  int() => 'odd int',
  double d when d.isNaN => 'NaN',
  double(isInfinite: true) => 'infinite',
  double() => 'double',
  String(length: 0) => 'empty string',
  String s when s.startsWith('#') => 'tag ${s.substring(1)}',
  String() => 'string',
  (int a, int b) when a == b => 'pair of equal ints',
  (int _, String _) || (String _, int _) => 'mixed pair',
  (num x, num y, z: num? z) => 'point $x $y $z',
  (:final String name, :final int age) => 'person $name $age',
  [] => 'empty list',
  [final only] => 'singleton ${describe(only)}',
  [final first, ..., final last] => 'list ${describe(first)}..${describe(last)}',
  {'type': 'user', 'id': final int id} => 'user $id',
  {'type': final String type} => 'map of $type',
  Map(isEmpty: true) => 'empty map',
  Set<int>() => 'int set',
  Expr() => 'expression',
  Function() => 'function',
  _ => 'other ${value.runtimeType}',
};

({int min, int max, double mean}) stats(Iterable<int> values) {
  var (min, max, sum, count) = (1 << 62, -(1 << 62), 0, 0);
  for (final v in values) {
    (min, max) = (v < min ? v : min, v > max ? v : max);
    sum += v;
    count++;
  }
  return (min: min, max: max, mean: count == 0 ? 0 : sum / count);
}

(T, T) swap<T>((T, T) pair) => (pair.$2, pair.$1);

extension type const Meters(double value) implements double {
  Meters operator +(Meters other) => Meters(value + other.value);
  Feet get inFeet => Feet(value * 3.28084);
}

extension type const Feet(double value) {
  Meters get inMeters => Meters(value / 3.28084);
}

extension type UserId._(int id) {
  UserId(int id) : this._(id.abs());
  bool get isAdmin => id < 100;
}

extension type JsonObject(Map<String, Object?> json) {
  String? string(String key) => json[key] as String?;
  int integer(String key, [int fallback = 0]) => (json[key] as int?) ?? fallback;
  JsonObject? child(String key) => switch (json[key]) {
    Map<String, Object?> m => JsonObject(m),
    _ => null,
  };
}

extension IterableStats<T extends num> on Iterable<T> {
  T? get maxOrNull => isEmpty ? null : reduce((a, b) => a > b ? a : b);
  Iterable<(int, T)> get numbered sync* {
    var i = 0;
    for (final v in this) {
      yield (i++, v);
    }
  }
}

Iterable<int> fibonacci(int count) sync* {
  var (a, b) = (0, 1);
  for (var i = 0; i < count; i++) {
    yield a;
    (a, b) = (b, a + b);
  }
}

Iterable<T> interleave<T>(Iterable<T> a, Iterable<T> b) sync* {
  final ia = a.iterator, ib = b.iterator;
  var hasA = ia.moveNext(), hasB = ib.moveNext();
  while (hasA || hasB) {
    if (hasA) {
      yield ia.current;
      hasA = ia.moveNext();
    }
    if (hasB) {
      yield ib.current;
      hasB = ib.moveNext();
    }
  }
}

Iterable<List<int>> permutations(List<int> items) sync* {
  if (items.length <= 1) {
    yield items;
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = [...items.sublist(0, i), ...items.sublist(i + 1)];
    for (final p in permutations(rest)) {
      yield [items[i], ...p];
    }
  }
}

Stream<int> ticks(int count, {Duration delay = Duration.zero}) async* {
  for (var i = 0; i < count; i++) {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    yield i;
  }
}

Stream<(int, String)> labelled(Stream<int> source) async* {
  try {
    await for (final v in source) {
      if (v % 7 == 6) continue;
      yield (v, describe(v));
      if (v > 100) return;
    }
  } finally {
    _log.add('labelled done');
  }
}

Stream<T> merge<T>(List<Stream<T>> streams) async* {
  for (final s in streams) {
    yield* s;
  }
}

final _log = Queue<String>();

Future<int> nestedTry(int depth) async {
  var result = 0;
  try {
    try {
      if (depth.isOdd) throw FormatException('odd', depth);
      result += await Future.value(depth);
    } on FormatException catch (e, st) {
      result -= e.offset ?? 0;
      _log.add('caught ${st.toString().length}');
      if (depth > 10) rethrow;
    } finally {
      result *= 2;
      if (depth == 3) {
        try {
          throw StateError('inner');
        } catch (_) {
          result += 1;
        } finally {
          result += 2;
        }
      }
    }
  } on Exception {
    result = -1;
  } finally {
    _log.add('nested $depth');
  }
  return result;
}

int syncFinally(List<int> values) {
  var total = 0;
  for (final v in values) {
    try {
      if (v == 0) continue;
      if (v < 0) break;
      try {
        total += 100 ~/ v;
      } finally {
        total++;
      }
    } on UnsupportedError {
      total = 0;
    } finally {
      total ^= v;
    }
  }
  return total;
}

typedef Transformer<A, B> = B Function(A input);

class Pipeline<A, B> {
  Pipeline(this._run);

  final Transformer<A, B> _run;

  B call(A input) => _run(input);

  Pipeline<A, C> then<C>(Transformer<B, C> next) =>
      Pipeline((input) => next(_run(input)));

  static Pipeline<T, T> identity<T>() => Pipeline((x) => x);
}

abstract class Repository<K extends Comparable<Object>, V> {
  final _store = SplayTreeMap<K, V>();

  void put(K key, V value) => _store[key] = value;
  V? get(K key) => _store[key];
  Iterable<MapEntry<K, V>> range(K from, K to) =>
      _store.entries.where((e) => e.key.compareTo(from) >= 0 && e.key.compareTo(to) < 0);
}

class StringRepository extends Repository<String, List<int>> {}

class IntRepository<V extends Object> extends Repository<int, V> {
  V getOr(int key, V Function() orElse) => get(key) ?? orElse();
}

class Box<T> {
  Box(this.value);
  final T value;
  Box<R> map<R>(R Function(T) f) => Box(f(value));
  Box<(T, R)> zip<R>(Box<R> other) => Box((value, other.value));
  @override
  String toString() => 'Box<$T>($value)';
}

R fold3<A, B, C, R>(A a, B b, C c, R Function(A, B, C) f) => f(a, b, c);

List<int Function(int)> makeCounters(int n) {
  final result = <int Function(int)>[];
  for (var i = 0; i < n; i++) {
    var calls = 0;
    result.add((x) {
      calls++;
      return x * i + calls;
    });
  }
  return result;
}

int Function() memoize(int Function() compute) {
  int? cache;
  return () => cache ??= compute();
}

Future<int> runLanguage(int seed) async {
  var h = seed;
  void mix(Object? o) => h = (h * 31 + o.hashCode) & 0x3fffffff;

  final expr = Let(
    'x',
    Num(seed),
    Add(
      Mul(Var('x'), Num(3)),
      Call('max', [Neg(Neg(Var('x'))), Call('sum', [Num(1), Num(2.5), Var('x')])]),
    ),
  );
  mix(evaluate(expr, const {}));
  for (final v in <Object?>[
    null,
    -seed,
    seed,
    seed + 1,
    double.nan,
    double.infinity,
    1.5,
    '',
    '#tag',
    'str',
    (seed, seed),
    (1, 'a'),
    (1.0, 2, z: 3),
    (name: 'n', age: seed),
    <int>[],
    [seed],
    [1, 2, 3],
    {'type': 'user', 'id': seed},
    {'type': 'other'},
    <String, int>{},
    <int>{1},
    expr,
    runLanguage,
    Object(),
  ]) {
    mix(describe(v));
  }
  final s = stats(fibonacci(30));
  mix(s.min);
  mix(s.max);
  mix(s.mean);
  mix(swap((seed, seed + 1)));
  final distance = const Meters(10) + Meters(seed.toDouble());
  mix(distance.inFeet.inMeters.value);
  mix(UserId(-seed).isAdmin);
  final json = JsonObject({
    'name': 'corpus',
    'nested': {'count': seed},
  });
  mix(json.string('name'));
  mix(json.child('nested')?.integer('count'));
  mix([3, 1, 4, 1, 5, 9, 2, 6].maxOrNull);
  mix([for (final (i, v) in [2.5, 1.5].numbered) i * v]);
  mix(interleave(fibonacci(5), [-1, -2, -3, -4, -5, -6, -7]).join());
  mix(permutations([1, 2, 3, 4]).length);
  await for (final (v, label) in labelled(
    merge([ticks(5), ticks(10), Stream.fromIterable(fibonacci(15))]),
  )) {
    mix(v);
    mix(label);
  }
  for (var d = 0; d < 6; d++) {
    mix(await nestedTry(d));
  }
  mix(syncFinally([5, 0, 3, -1, 2]));
  final pipeline = Pipeline.identity<int>()
      .then((x) => x * 2)
      .then((x) => '$x')
      .then((s) => s.padLeft(8, '0'))
      .then((s) => s.codeUnits);
  mix(pipeline(seed).length);
  final repo = StringRepository()
    ..put('b', [2])
    ..put('a', [1])
    ..put('c', [3]);
  mix(repo.range('a', 'c').map((e) => e.key).join());
  mix(IntRepository<String>().getOr(seed, () => 'missing'));
  mix(Box(seed).map((v) => v.toString()).zip(Box(1.5)).toString());
  mix(fold3(1, '2', 3.0, (a, b, c) => '$a$b$c'));
  final counters = makeCounters(5);
  mix(counters.map((c) => c(seed) + c(seed)).toList());
  final memo = memoize(() => seed * seed);
  mix(memo() + memo());
  mix(_log.length);
  return h;
}
