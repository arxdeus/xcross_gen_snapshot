// The pub-heavy corpus app (docs/CORPUS.md): pure Dart and Flutter
// packages only (no plugins, so `flutter build ios` needs no CocoaPods or
// Swift packages), each one used for real so tree shaking keeps a big part
// of every package in the snapshot.

import 'dart:async';
import 'dart:convert';

import 'package:built_collection/built_collection.dart';
import 'package:collection/collection.dart';
import 'package:convert/convert.dart' as convert;
import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' as fp;
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:petitparser/petitparser.dart';
import 'package:provider/provider.dart' as provider;
import 'package:rxdart/rxdart.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:uuid/uuid.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:xml/xml.dart';
import 'package:yaml/yaml.dart';

final _log = Logger('pub_heavy');

class Item extends Equatable {
  const Item(this.id, this.name, this.price);

  final int id;
  final String name;
  final Decimal price;

  @override
  List<Object?> get props => [id, name, price];
}

sealed class CartEvent {}

final class AddItem extends CartEvent {
  AddItem(this.item);
  final Item item;
}

final class RemoveItem extends CartEvent {
  RemoveItem(this.id);
  final int id;
}

final class ClearCart extends CartEvent {}

class CartBloc extends Bloc<CartEvent, IList<Item>> {
  CartBloc() : super(const IListConst([])) {
    on<AddItem>((event, emit) => emit(state.add(event.item)));
    on<RemoveItem>(
      (event, emit) => emit(state.removeWhere((i) => i.id == event.id)),
    );
    on<ClearCart>((event, emit) => emit(const IListConst([])));
  }

  Decimal get total => state.fold(Decimal.zero, (sum, i) => sum + i.price);
}

class CounterCubit extends Cubit<int> {
  CounterCubit() : super(0);
  void increment() => emit(state + 1);
}

class TodoNotifier extends Notifier<BuiltList<String>> {
  @override
  BuiltList<String> build() => BuiltList(['parse', 'compile', 'verify']);

  void add(String todo) => state = state.rebuild((b) => b.add(todo));
}

final todoProvider = NotifierProvider<TodoNotifier, BuiltList<String>>(
  TodoNotifier.new,
);

final greetingProvider = FutureProvider.family<String, String>(
  (ref, name) async => Intl.message('Hello $name', name: 'greeting'),
);

Parser<num> buildCalculator() {
  final builder = ExpressionBuilder<num>();
  builder.primitive(
    digit()
        .plus()
        .seq(char('.').seq(digit().plus()).optional())
        .flatten()
        .trim()
        .map(num.parse),
  );
  builder.group().wrapper(char('(').trim(), char(')').trim(), (l, v, r) => v);
  builder.group().prefix(char('-').trim(), (op, a) => -a);
  builder.group().right(char('^').trim(), (a, op, b) => a * b);
  builder.group()
    ..left(char('*').trim(), (a, op, b) => a * b)
    ..left(char('/').trim(), (a, op, b) => a / b);
  builder.group()
    ..left(char('+').trim(), (a, op, b) => a + b)
    ..left(char('-').trim(), (a, op, b) => a - b);
  return builder.build().end();
}

fp.Either<String, int> parsePositive(String s) => fp.Either.tryCatch(
  () => int.parse(s),
  (e, _) => 'not a number: $s',
).flatMap((n) => n > 0 ? fp.right(n) : fp.left('not positive: $n'));

Future<String> exercise(int seed) async {
  final out = StringBuffer();
  void add(Object? o) => out.writeln(o);

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) => add('${r.level.name} ${r.message}'));
  _log.info('seed $seed');

  final getIt = GetIt.instance;
  if (!getIt.isRegistered<Uuid>()) getIt.registerSingleton(const Uuid());
  add(getIt<Uuid>().v5(Namespace.url.value, 'https://example.com/$seed'));

  final cart = CartBloc();
  cart
    ..add(AddItem(Item(1, 'compiler', Decimal.parse('19.99'))))
    ..add(AddItem(Item(2, 'kernel', Decimal.parse('0.01'))))
    ..add(RemoveItem(1));
  await Future<void>.delayed(Duration.zero);
  add(cart.total);
  await cart.close();

  final container = ProviderContainer();
  container.read(todoProvider.notifier).add('publish $seed');
  add(container.read(todoProvider));
  add(await container.read(greetingProvider('corpus').future));
  container.dispose();

  add(buildCalculator().parse('1 + 2 * (3 - -4.5) / 7 ^ 2').value);
  add(
    md.markdownToHtml(
      '# Title\n\n* a **bold** item\n* `code`\n\n| a | b |\n|---|---|\n| 1 | 2 |',
      extensionSet: md.ExtensionSet.gitHubWeb,
    ),
  );
  final doc = XmlDocument.parse(
    '<root><item id="1">x</item><item id="$seed"/></root>',
  );
  add(doc.findAllElements('item').map((e) => e.getAttribute('id')).join(','));
  final yaml = loadYaml('a: [1, 2, {b: c}]\nseed: $seed\n') as YamlMap;
  add(jsonEncode(yaml));
  add(
    csv.encode([
      ['name', 'value'],
      ['a,b', seed],
      ['"quoted"', 1.5],
    ]),
  );
  add(csv.decode('x,y\n1,"2,3"\n').length);
  add(
    html.parse('<p class="a">Hello <b>$seed</b></p>').querySelector('b')?.text,
  );
  add(sha256.convert(utf8.encode('$seed')));
  add(md5.convert(utf8.encode('$seed')));
  add(Hmac(sha1, [1, 2, 3]).convert([seed & 0xff]));
  add(convert.hex.encode([seed & 0xff, 0xab]));
  add(Int64(seed) * Int64.parseHex('7fffffffffff') >> 3);
  add(Decimal.parse('1.1') * Decimal.fromInt(seed) / Decimal.fromInt(3));
  add(DateFormat.yMMMMEEEEd('en_US').format(DateTime.utc(2024, 2, 29)));
  add(NumberFormat.currency(locale: 'en_US', symbol: r'$').format(seed * 1.25));
  add(NumberFormat.compact().format(seed * 1000000));
  add(Bidi.stripHtmlIfNeeded('<b>x</b>'));
  add(
    timeago.format(
      DateTime.utc(2024).subtract(Duration(hours: seed)),
      clock: DateTime.utc(2024),
    ),
  );
  add('👨‍👩‍👧‍👦 family'.characters.length);
  add(parsePositive('$seed').match((l) => l, (r) => '$r'));
  add(parsePositive('-1').getLeft());
  add(fp.Option.of(seed).map((v) => v * 2).getOrElse(() => 0));
  add(
    const DeepCollectionEquality().equals(
      [
        1,
        {'a': 2},
      ],
      [
        1,
        {'a': 2},
      ],
    ),
  );
  add(groupBy([1, 2, 3, 4, 5, 6], (int v) => v % 3));
  add(mergeMaps({'a': 1}, {'b': seed}));
  add(BuiltMap<String, int>({'x': seed}).rebuild((b) => b['y'] = 2));
  add(IMap({'k': seed}).add('j', 1).keys.toList());
  add(ISet([3, 1, 2]).withConfig(const ConfigSet(sort: true)).toList());
  final m = vm.Matrix4.rotationZ(seed / 100)
    ..translateByVector3(vm.Vector3(1, 2, 3));
  add(
    m.transform3(vm.Vector3(1, 0, 0)).storage.map((v) => v.toStringAsFixed(3)),
  );
  add(vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), 1.0).w);

  final subject = BehaviorSubject<int>.seeded(seed);
  final combined = Rx.combineLatest2(
    subject,
    Stream.fromIterable([1, 2, 3]),
    (a, b) => a + b,
  ).debounceTime(Duration.zero).distinct().take(1);
  add(await combined.first);
  await subject.close();

  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://example.invalid',
      connectTimeout: Duration.zero,
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(
            requestOptions: options,
            data: {'ok': true},
            statusCode: 200,
          ),
        );
      },
    ),
  );
  add((await dio.get<Map<String, dynamic>>('/status')).data);
  add(http.Request('POST', Uri.parse('https://example.invalid/x')).method);
  return out.toString();
}

final _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomePage(),
      routes: [
        GoRoute(
          path: 'details/:id',
          builder: (context, state) =>
              DetailsPage(id: state.pathParameters['id']!),
        ),
      ],
    ),
  ],
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      child: provider.MultiProvider(
        providers: [
          provider.Provider<Future<String>>.value(
            value: exercise(DateTime.now().millisecond),
          ),
        ],
        child: BlocProvider(
          create: (_) => CounterCubit(),
          child: MaterialApp.router(routerConfig: _router),
        ),
      ),
    ),
  );
}

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todos = ref.watch(todoProvider);
    final count = context.watch<CounterCubit>().state;
    return Scaffold(
      appBar: AppBar(title: Text('pub_heavy ${todos.length} $count')),
      body: FutureBuilder<String>(
        future: provider.Provider.of<Future<String>>(context),
        builder: (context, snapshot) => SingleChildScrollView(
          child: Text(snapshot.data ?? snapshot.error?.toString() ?? '...'),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          context.read<CounterCubit>().increment();
          context.go('/details/$count');
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: Text('details $id')));
}
