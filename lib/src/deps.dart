/// A reader for gclient `DEPS` files.
///
/// DEPS files are Python, but in practice they only use a small literal
/// subset: assignments of dicts, lists, strings, booleans and numbers, string
/// concatenation with `+` (and implicit adjacent-literal concatenation), and
/// the `Var("name")` / `Str("value")` helpers. This parser evaluates exactly
/// that subset, which is enough for the Flutter and Dart SDK DEPS files.
library;

/// Thrown when a DEPS file uses syntax outside the supported subset or lacks
/// an entry the build needs.
class DepsException implements Exception {
  DepsException(this.message);

  final String message;

  @override
  String toString() => 'DepsException: $message';
}

/// Parses [source] and returns the top-level assignments.
///
/// `Var("x")` is resolved against the `vars` dict assigned earlier in the same
/// file, which is how gclient evaluates it.
Map<String, Object?> parseDeps(String source) =>
    _DepsParser(_tokenize(source)).parseFile();

/// The parts of a Dart SDK `DEPS` file the gen_snapshot build depends on.
class DartDeps {
  DartDeps._(this._vars, this._deps);

  /// Parses the Dart SDK `DEPS` file content.
  factory DartDeps.parse(String source) {
    final top = parseDeps(source);
    final vars = top['vars'];
    final deps = top['deps'];
    if (vars is! Map<String, Object?> || deps is! Map<String, Object?>) {
      throw DepsException('DEPS has no vars/deps dicts');
    }
    return DartDeps._(vars, deps);
  }

  final Map<String, Object?> _vars;
  final Map<String, Object?> _deps;

  String get _root => (_vars['dart_root'] as String?) ?? 'sdk';

  /// Value of a string entry of the `vars` dict.
  String variable(String name) {
    final value = _vars[name];
    if (value is! String) {
      throw DepsException('DEPS var "$name" is missing or not a string');
    }
    return value;
  }

  Object? _dep(String path) {
    final key = '$_root/$path';
    if (!_deps.containsKey(key)) {
      throw DepsException('DEPS has no entry for "$key"');
    }
    return _deps[key];
  }

  /// The git dependency checked out at [path] (relative to the SDK root).
  GitDep gitDep(String path) {
    var value = _dep(path);
    if (value is Map<String, Object?>) value = value['url'];
    if (value is! String) {
      throw DepsException('DEPS entry "$path" is not a git dependency');
    }
    final at = value.lastIndexOf('@');
    if (at <= 0) {
      throw DepsException('DEPS entry "$path" is not pinned: $value');
    }
    return GitDep(
      path: path,
      url: value.substring(0, at),
      revision: value.substring(at + 1),
    );
  }

  /// The single CIPD package deployed at [path] (relative to the SDK root).
  CipdDep cipdDep(String path) {
    final value = _dep(path);
    if (value is! Map<String, Object?> || value['dep_type'] != 'cipd') {
      throw DepsException('DEPS entry "$path" is not a CIPD dependency');
    }
    final packages = value['packages'];
    if (packages is! List || packages.length != 1) {
      throw DepsException('DEPS entry "$path" must have exactly one package');
    }
    final package = packages.single;
    if (package is! Map<String, Object?> ||
        package['package'] is! String ||
        package['version'] is! String) {
      throw DepsException('DEPS entry "$path" has a malformed package');
    }
    return CipdDep(
      path: path,
      package: package['package'] as String,
      version: package['version'] as String,
    );
  }
}

/// A git dependency pinned to a revision.
class GitDep {
  const GitDep({required this.path, required this.url, required this.revision});

  /// Destination relative to the Dart SDK root.
  final String path;
  final String url;
  final String revision;

  /// Gitiles archive URL of the pinned tree (`+archive/<rev>.tar.gz`).
  Uri get archiveUrl {
    var base = url;
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    return Uri.parse('$base/+archive/$revision.tar.gz');
  }

  @override
  String toString() => '$path <- $url@$revision';
}

/// A CIPD package pin. [package] may contain the `${{platform}}` placeholder.
class CipdDep {
  const CipdDep({
    required this.path,
    required this.package,
    required this.version,
  });

  final String path;
  final String package;
  final String version;

  /// The package name with `${{platform}}` replaced by [platform].
  String packageFor(String platform) =>
      package.replaceAll(r'${{platform}}', platform);

  @override
  String toString() => '$path <- $package@$version';
}

/// The Dart SDK revision pinned by a Flutter (monorepo) `DEPS` file.
String dartRevisionFromFlutterDeps(String source) {
  final top = parseDeps(source);
  final vars = top['vars'];
  final rev = vars is Map<String, Object?> ? vars['dart_revision'] : null;
  if (rev is! String || !_isSha(rev)) {
    throw DepsException('Flutter DEPS has no valid dart_revision');
  }
  return rev;
}

bool _isSha(String s) => RegExp(r'^[0-9a-f]{40}$').hasMatch(s);

// ---------------------------------------------------------------------------
// Tokenizer and parser.

enum _T { string, name, number, punct, eof }

class _Token {
  _Token(this.type, this.value, this.line);

  final _T type;
  final String value;
  final int line;

  @override
  String toString() => '$type "$value" (line $line)';
}

List<_Token> _tokenize(String s) {
  final tokens = <_Token>[];
  var i = 0;
  var line = 1;
  bool isNameStart(int c) =>
      (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
  bool isDigit(int c) => c >= 0x30 && c <= 0x39;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    final ch = s[i];
    if (ch == '\n') {
      line++;
      i++;
    } else if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\\') {
      // A trailing backslash is a Python line continuation.
      i++;
    } else if (ch == '#') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (ch == '"' || ch == "'") {
      final triple = s.startsWith(ch * 3, i);
      if (triple) {
        throw DepsException(
          'triple-quoted strings are not supported '
          '(line $line)',
        );
      }
      final buf = StringBuffer();
      i++;
      while (true) {
        if (i >= s.length || s[i] == '\n') {
          throw DepsException('unterminated string (line $line)');
        }
        final d = s[i];
        if (d == ch) {
          i++;
          break;
        }
        if (d == '\\' && i + 1 < s.length) {
          final e = s[i + 1];
          buf.write(switch (e) {
            'n' => '\n',
            't' => '\t',
            '\\' => '\\',
            "'" => "'",
            '"' => '"',
            _ => '\\$e',
          });
          i += 2;
          continue;
        }
        buf.write(d);
        i++;
      }
      tokens.add(_Token(_T.string, buf.toString(), line));
    } else if (isNameStart(c)) {
      final start = i;
      while (i < s.length &&
          (isNameStart(s.codeUnitAt(i)) || isDigit(s.codeUnitAt(i)))) {
        i++;
      }
      tokens.add(_Token(_T.name, s.substring(start, i), line));
    } else if (isDigit(c) ||
        (ch == '-' && i + 1 < s.length && isDigit(s.codeUnitAt(i + 1)))) {
      final start = i;
      i++;
      while (i < s.length && isDigit(s.codeUnitAt(i))) {
        i++;
      }
      tokens.add(_Token(_T.number, s.substring(start, i), line));
    } else if ('{}[]():,=+'.contains(ch)) {
      tokens.add(_Token(_T.punct, ch, line));
      i++;
    } else {
      throw DepsException('unexpected character "$ch" (line $line)');
    }
  }
  tokens.add(_Token(_T.eof, '', line));
  return tokens;
}

class _DepsParser {
  _DepsParser(this._tokens);

  final List<_Token> _tokens;
  int _pos = 0;
  final Map<String, Object?> _top = {};

  /// True while parsing the `vars` dict; its first dict literal is published
  /// as `vars` immediately so later entries can `Var()` earlier ones.
  bool _buildingVars = false;

  _Token get _peek => _tokens[_pos];

  _Token _next() => _tokens[_pos++];

  bool _isPunct(String p) => _peek.type == _T.punct && _peek.value == p;

  void _expect(String p) {
    final t = _next();
    if (t.type != _T.punct || t.value != p) {
      throw DepsException('expected "$p", got $t');
    }
  }

  Map<String, Object?> parseFile() {
    while (_peek.type != _T.eof) {
      final name = _next();
      if (name.type != _T.name) {
        throw DepsException('expected an assignment, got $name');
      }
      _expect('=');
      if (name.value == 'vars') _buildingVars = true;
      _top[name.value] = _expr();
      _buildingVars = false;
    }
    return _top;
  }

  Object? _expr() {
    var value = _atom();
    while (_isPunct('+')) {
      _next();
      final rhs = _atom();
      if (value is String && rhs is String) {
        value = value + rhs;
      } else if (value is List && rhs is List) {
        value = [...value, ...rhs];
      } else {
        throw DepsException('cannot add $value and $rhs (line ${_peek.line})');
      }
    }
    return value;
  }

  Object? _atom() {
    final t = _next();
    switch (t.type) {
      case _T.string:
        var s = t.value;
        // Implicit concatenation of adjacent literals.
        while (_peek.type == _T.string) {
          s += _next().value;
        }
        return s;
      case _T.number:
        return int.parse(t.value);
      case _T.name:
        switch (t.value) {
          case 'True':
            return true;
          case 'False':
            return false;
          case 'None':
            return null;
          case 'Var':
            _expect('(');
            final name = _expr();
            _expect(')');
            if (name is! String) {
              throw DepsException('Var() needs a string (line ${t.line})');
            }
            final vars = _top['vars'];
            if (vars is Map<String, Object?> && vars.containsKey(name)) {
              return vars[name];
            }
            // gclient built-ins (host_os, checkout_*, ...) are not in the
            // file. Keep a placeholder; nothing this package reads uses them.
            return '{$name}';
          case 'Str':
            _expect('(');
            final value = _expr();
            _expect(')');
            return value;
        }
        throw DepsException('unsupported name ${t.value} (line ${t.line})');
      case _T.punct:
        switch (t.value) {
          case '{':
            final map = <String, Object?>{};
            if (_buildingVars && !_top.containsKey('vars')) _top['vars'] = map;
            while (!_isPunct('}')) {
              final key = _expr();
              if (key is! String) {
                throw DepsException('non-string dict key (line ${t.line})');
              }
              _expect(':');
              map[key] = _expr();
              if (!_isPunct('}')) _expect(',');
            }
            _next();
            return map;
          case '[':
            final list = <Object?>[];
            while (!_isPunct(']')) {
              list.add(_expr());
              if (!_isPunct(']')) _expect(',');
            }
            _next();
            return list;
          case '(':
            final value = _expr();
            _expect(')');
            return value;
        }
        throw DepsException('unexpected $t');
      case _T.eof:
        throw DepsException('unexpected end of file');
    }
  }
}
