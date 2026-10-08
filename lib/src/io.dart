import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Logs a progress line on stderr (stdout is reserved for machine output).
void log(String message) => stderr.writeln('[xgs] $message');

/// HTTP helpers with retries: googlesource, CIPD and GitHub all rate-limit or
/// flake now and then.
class Net {
  Net({http.Client? client, this.attempts = 6})
    : _client = client ?? http.Client();

  final http.Client _client;
  final int attempts;

  void close() => _client.close();

  Future<T> _retry<T>(String what, Future<T> Function() body) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await body();
      } on _Permanent catch (e) {
        throw HttpException('$what: ${e.message}');
      } catch (e) {
        if (attempt >= attempts) rethrow;
        final delay = Duration(seconds: 2 * attempt * attempt);
        log(
          '$what failed ($e), retry $attempt/${attempts - 1} in '
          '${delay.inSeconds}s',
        );
        await Future<void>.delayed(delay);
      }
    }
  }

  /// GETs [url] as text.
  Future<String> getString(Uri url, {Map<String, String>? headers}) =>
      _retry('GET $url', () async {
        final response = await _client
            .get(url, headers: headers)
            .timeout(const Duration(minutes: 2));
        _check(response.statusCode, url);
        return utf8.decode(response.bodyBytes);
      });

  /// POSTs JSON to [url] and returns the body.
  Future<String> postJson(
    Uri url,
    Object body, {
    Map<String, String>? headers,
  }) => _retry('POST $url', () async {
    final response = await _client
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            ...?headers,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(minutes: 2));
    _check(response.statusCode, url);
    return utf8.decode(response.bodyBytes);
  });

  /// Streams [url] into [file] and returns the sha256 of the bytes.
  Future<Digest> download(Uri url, File file) =>
      _retry('download $url', () async {
        final request = http.Request('GET', url);
        final response = await _client
            .send(request)
            .timeout(const Duration(minutes: 2));
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          _check(response.statusCode, url);
        }
        file.parent.createSync(recursive: true);
        final partial = File('${file.path}.part');
        final sink = partial.openWrite();
        final digestSink = _DigestSink();
        final hasher = sha256.startChunkedConversion(digestSink);
        var bytes = 0;
        try {
          await response.stream.timeout(const Duration(minutes: 2)).forEach((
            chunk,
          ) {
            hasher.add(chunk);
            sink.add(chunk);
            bytes += chunk.length;
          });
        } finally {
          await sink.close();
        }
        final expected = response.contentLength;
        if (expected != null && expected != bytes) {
          throw HttpException('short read: $bytes of $expected bytes');
        }
        hasher.close();
        if (file.existsSync()) file.deleteSync();
        partial.renameSync(file.path);
        return digestSink.value;
      });

  void _check(int status, Uri url) {
    if (status == 200) return;
    // 4xx (except throttling) will not get better by retrying.
    if (status >= 400 && status < 500 && status != 408 && status != 429) {
      throw _Permanent('HTTP $status for $url');
    }
    throw HttpException('HTTP $status', uri: url);
  }
}

class _Permanent implements Exception {
  _Permanent(this.message);

  final String message;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// sha256 of a file, as lowercase hex.
Future<String> sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// sha256 of bytes, as lowercase hex.
String sha256Bytes(List<int> bytes) => sha256.convert(bytes).toString();

/// Runs [executable] and throws if it fails. Output is inherited so CI logs
/// show it live.
Future<void> run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  log(
    '\$ $executable ${arguments.join(' ')}'
    '${workingDirectory == null ? '' : '   (in $workingDirectory)'}',
  );
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) {
    throw ProcessException(executable, arguments, 'exit code $code', code);
  }
}

/// Runs [executable] and returns its trimmed stdout, throwing on failure.
Future<String> capture(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  return '${result.stdout}'.trim();
}

/// Converts bytes to a [Uint8List] without copying when possible.
Uint8List asBytes(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);
