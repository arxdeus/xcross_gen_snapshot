// RegExp stress: every RegExp feature the VM's irregexp port handles, with
// patterns that are only known at run time as well as literal ones.

final regexps = <String, RegExp>{
  'named': RegExp(r'(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})'),
  'named_many': RegExp(
    r'(?<z>z+)(?<y>y+)(?<x>x+)(?<w>w+)(?<v>v+)(?<u>u+)(?<t>t+)(?<s>s+)'
    r'(?<r>r+)(?<q>q+)(?<p>p+)(?<o>o+)(?<n>n+)(?<m>m+)(?<l>l+)(?<k>k+)',
  ),
  'named_dup_order': RegExp(r'(?<b>b)|(?<a>a)|(?<c>c)(?<aa>a)(?<ab>b)'),
  'unicode_props': RegExp(
    // The analyzer checks with JS rules; the VM accepts this (unicode mode).
    // ignore: valid_regexps
    r'[\p{L}\p{Mn}\p{Nd}]+|\p{Script=Greek}+|\p{Extended_Pictographic}',
    unicode: true,
  ),
  'unicode_sets': RegExp(r'[\u{1F600}-\u{1F64F}\u{10000}-\u{10FFFF}]', unicode: true),
  'lookbehind': RegExp(r'(?<=\$)\d+(\.\d\d)?(?![\d.])'),
  'neg_lookbehind': RegExp(r'(?<!\\)"((?:[^"\\]|\\.)*)"'),
  'lookahead_chain': RegExp(r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[^\w\s]).{8,}$'),
  'case_insensitive': RegExp(r'[a-zäöüßẞ\u0130\u0131k\u212a]+[^\W\d_]', caseSensitive: false),
  'case_insensitive_unicode': RegExp(
    r'[\u00c0-\u024f\u0370-\u03ff\u0400-\u04ff]+σς',
    caseSensitive: false,
    unicode: true,
  ),
  'backrefs': RegExp(r'(\w)(\w)?\2\1|(?<q>["\x27]).*?\k<q>'),
  'multiline_dotall': RegExp(r'^begin.*?end$', multiLine: true, dotAll: true),
  'alternation_keywords': RegExp(
    r'\b(?:abstract|as|assert|async|await|base|break|case|catch|class|const|'
    r'continue|covariant|default|deferred|do|dynamic|else|enum|export|extends|'
    r'extension|external|factory|false|final|finally|for|Function|get|hide|if|'
    r'implements|import|in|interface|is|late|library|mixin|new|null|of|on|'
    r'operator|part|required|rethrow|return|sealed|set|show|static|super|'
    r'switch|sync|this|throw|true|try|type|typedef|var|void|when|while|with|'
    r'yield)\b',
  ),
  'alternation_common_prefix': RegExp(
    r'international|internationalization|internationalize|internet|interval|'
    r'intervene|interview|intern|interior|interpret|interrupt|intersect|'
    r'abc|abd|abe|abf|ab|a|bcd|bce|bc|b|cde|cd|c',
  ),
  'alternation_ci': RegExp(
    r'Alpha|alpha|ALPHA|Beta|Gamma|gamma|DELTA|delta|Epsilon|zeta|Zeta|Eta|'
    r'theta|Iota|kappa|Lambda|mu|Nu|xi|Omicron|pi|Rho|sigma|Tau|upsilon|Phi|'
    r'chi|Psi|omega|ΑΛΦΑ|άλφα|Ωμέγα|ωμέγα',
    caseSensitive: false,
    unicode: true,
  ),
  'classes': RegExp(r'[\d\s\w-]+|[^\x00-\x7f]+|[\[\]{}()<>]|[\u2000-\u206f]'),
  'quantifiers': RegExp(r'a{2,5}?b{3}c*?d+?e??(?:fg){1,}?'),
  'email': RegExp(r'^[\w.+-]+@(?:[a-zA-Z\d-]+\.)+[a-zA-Z]{2,}$'),
  'word_boundary_ci': RegExp(r'\B[ſK]\w*\b|\bſt', caseSensitive: false),
};

final _dynamicSources = <String>[
  r'(?<a>\d+)\s*(?<op>[-+*/])\s*(?<b>\d+)',
  r'(?:(?<=a)b|(?<!c)d)+',
  r'[^\p{Lu}]+',
  for (var i = 0; i < 40; i++) 'w$i(?:x${i * 3}|y${i ~/ 2}|z)+',
];

/// RegExps whose patterns depend on [seed] (compiled at run time only).
List<RegExp> dynamicRegexps(int seed) => [
  for (final (i, source) in _dynamicSources.indexed)
    RegExp(
      source,
      caseSensitive: (seed + i).isEven,
      unicode: source.contains(r'\p') || (seed + i) % 3 == 0,
      multiLine: (seed + i) % 5 == 0,
    ),
];

/// Runs every RegExp on [input] and folds the results into a checksum.
int exerciseRegexps(String input, int seed) {
  var h = seed;
  void mix(Object? o) => h = (h * 31 + o.hashCode) & 0x3fffffff;
  for (final MapEntry(:key, :value) in regexps.entries) {
    for (final m in value.allMatches(input)) {
      mix(key);
      mix(m.start);
      mix(m.group(0));
      for (final name in m.groupNames) {
        mix(m.namedGroup(name));
      }
    }
    mix(input.replaceAllMapped(value, (m) => '<${m.groupCount}>').length);
    mix(input.split(value).length);
  }
  for (final re in dynamicRegexps(seed)) {
    mix(re.firstMatch(input)?.group(0));
    mix(re.hasMatch(input));
  }
  return h;
}
