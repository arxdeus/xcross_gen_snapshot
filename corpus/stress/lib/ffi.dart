// dart:ffi: structs, unions, packed structs, inline arrays, native
// callables and native function lookups (resolved in the process at run
// time, so nothing is linked).

import 'dart:ffi';

final class Point extends Struct {
  @Double()
  external double x;

  @Double()
  external double y;
}

final class Rect extends Struct {
  external Point origin;
  external Point size;

  @Int32()
  external int flags;

  @Array(16)
  external Array<Uint8> tag;
}

@Packed(1)
final class PackedHeader extends Struct {
  @Uint8()
  external int kind;

  @Uint32()
  external int length;

  @Uint16()
  external int checksum;

  @Array(3, 4)
  external Array<Array<Int16>> matrix;
}

final class Number extends Union {
  @Int64()
  external int asInt;

  @Double()
  external double asDouble;

  @Array(8)
  external Array<Uint8> bytes;
}

final class Node extends Struct {
  @IntPtr()
  external int value;

  external Pointer<Node> next;

  external Pointer<NativeFunction<Int32 Function(Int32, Int32)>> compare;
}

final class Mixed extends Struct {
  @Int8()
  external int a;

  @Float()
  external double b;

  @Int16()
  external int c;

  @Bool()
  external bool d;

  external Number number;

  @Array(2)
  external Array<Point> points;
}

typedef CompareNative = Int32 Function(Int32, Int32);
typedef StrlenNative = Size Function(Pointer<Char>);
typedef Strlen = int Function(Pointer<Char>);
typedef QsortNative =
    Void Function(
      Pointer<Void>,
      Size,
      Size,
      Pointer<NativeFunction<Int32 Function(Pointer<Void>, Pointer<Void>)>>,
    );
typedef Qsort =
    void Function(
      Pointer<Void>,
      int,
      int,
      Pointer<NativeFunction<Int32 Function(Pointer<Void>, Pointer<Void>)>>,
    );

@Native<Pointer<Void> Function(Size)>(symbol: 'malloc')
external Pointer<Void> _malloc(int size);

@Native<Void Function(Pointer<Void>)>(symbol: 'free')
external void _free(Pointer<Void> pointer);

@Native<Int32 Function(Pointer<Void>, Pointer<Void>, Size)>(symbol: 'memcmp')
external int _memcmp(Pointer<Void> a, Pointer<Void> b, int size);

int _compareInts(Pointer<Void> a, Pointer<Void> b) =>
    a.cast<Int32>().value - b.cast<Int32>().value;

int _compareNative(int a, int b) => a - b;

Pointer<T> _alloc<T extends NativeType>(int bytes) => _malloc(bytes).cast<T>();

int runFfi(int seed) {
  var h = seed;
  void mix(Object? o) => h = (h * 31 + o.hashCode) & 0x3fffffff;
  mix(sizeOf<Rect>());
  mix(sizeOf<PackedHeader>());
  mix(sizeOf<Number>());
  mix(sizeOf<Mixed>());

  final rect = _alloc<Rect>(sizeOf<Rect>());
  rect.ref
    ..origin.x = seed.toDouble()
    ..origin.y = -1.5
    ..size.x = 3
    ..size.y = 4
    ..flags = seed ^ 0x55;
  for (var i = 0; i < 16; i++) {
    rect.ref.tag[i] = i * seed;
  }
  mix(rect.ref.origin.x * rect.ref.size.y + rect.ref.tag[7]);

  final header = _alloc<PackedHeader>(sizeOf<PackedHeader>());
  header.ref
    ..kind = 3
    ..length = 0xffffffff
    ..checksum = seed & 0xffff;
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 4; j++) {
      header.ref.matrix[i][j] = i * 4 - j;
    }
  }
  mix(header.ref.matrix[2][3] + header.ref.length);

  final number = _alloc<Number>(sizeOf<Number>());
  number.ref.asDouble = seed / 7;
  mix(number.ref.asInt ^ number.ref.bytes[6]);

  final mixed = _alloc<Mixed>(sizeOf<Mixed>());
  mixed.ref
    ..a = -seed
    ..b = 0.1
    ..c = 300
    ..d = seed.isOdd;
  mixed.ref.points[1].x = 2;
  mix(mixed.ref.b + mixed.ref.points[1].x);
  mix(_memcmp(rect.cast(), mixed.cast(), 8).sign);

  final compare = NativeCallable<CompareNative>.isolateLocal(
    _compareNative,
    exceptionalReturn: 0,
  );
  final nodes = _alloc<Node>(sizeOf<Node>() * 4);
  for (var i = 0; i < 4; i++) {
    nodes[i]
      ..value = seed * i
      ..next = i == 3 ? nullptr : nodes + (i + 1)
      ..compare = compare.nativeFunction;
  }
  var cursor = nodes;
  while (cursor != nullptr) {
    final f = cursor.ref.compare.asFunction<int Function(int, int)>();
    mix(f(cursor.ref.value, seed));
    cursor = cursor.ref.next;
  }
  compare.close();

  final lookup = DynamicLibrary.process();
  final strlen = lookup.lookupFunction<StrlenNative, Strlen>('strlen');
  final text = _alloc<Uint8>(16);
  for (var i = 0; i < 15; i++) {
    text[i] = 0x61 + (i + seed) % 26;
  }
  text[15] = 0;
  mix(strlen(text.cast()));

  final qsort = lookup.lookupFunction<QsortNative, Qsort>('qsort');
  final ints = _alloc<Int32>(sizeOf<Int32>() * 32);
  for (var i = 0; i < 32; i++) {
    ints[i] = (i * 7919 + seed) % 101;
  }
  qsort(
    ints.cast(),
    32,
    sizeOf<Int32>(),
    Pointer.fromFunction<Int32 Function(Pointer<Void>, Pointer<Void>)>(
      _compareInts,
      0,
    ),
  );
  mix(ints.asTypedList(32).join(','));

  for (final p in <Pointer<NativeType>>[rect, header, number, mixed, nodes, text, ints]) {
    _free(p.cast());
  }
  return h;
}
