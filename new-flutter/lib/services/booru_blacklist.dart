import '../data/models.dart';

/// Matches the native reader's blacklist: lines are OR rules, and terms within
/// a line are ANDed. A leading minus negates one term. Only `*` is a wildcard.
class BooruBlacklist {
  BooruBlacklist(Iterable<String> entries)
    : _rules = [
        for (final entry in entries)
          for (final line in entry.split(_newlines))
            if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
              [
                for (final term in line.toLowerCase().trim().split(_spaces))
                  _BlacklistTerm(term),
              ],
      ];

  static final _newlines = RegExp(r'[\n\r\u000b\u000c\u0085\u2028\u2029]');
  static final _spaces = RegExp(r'\s+');
  static final _plainTag = RegExp(r'^[a-z0-9_][a-z0-9_()-]*$');
  final List<List<_BlacklistTerm>> _rules;

  /// A server exclusion is safe only when the whole rule is one literal,
  /// positive tag. Forwarding an AND rule as separate negatives would also
  /// hide posts that match only part of it. Servers differ in metatag syntax.
  List<String> get queryExclusions => {
    for (final rule in _rules)
      if (rule.length == 1 &&
          !rule.single.negative &&
          _plainTag.hasMatch(rule.single.value))
        '-${rule.single.value}',
  }.toList(growable: false);

  bool contains(CatalogItem item) {
    final tags = item.tags.map((tag) => tag.toLowerCase()).toSet();
    final rating = _normalizeRating(item.rating.toLowerCase());
    return _rules.any(
      (rule) => rule.every((term) {
        final bool matches;
        if (term.value.startsWith('rating:')) {
          matches = _normalizeRating(term.value.substring(7)) == rating;
        } else if (term.value.startsWith('id:')) {
          matches =
              item.remoteId != null &&
              '${item.remoteId}' == term.value.substring(3);
        } else if (term.value.contains('*')) {
          matches = tags.any((tag) => _wildcardMatches(term.value, tag));
        } else {
          matches = tags.contains(term.value);
        }
        return term.negative ? !matches : matches;
      }),
    );
  }

  static String _normalizeRating(String rating) => switch (rating) {
    'g' || 'general' || 'safe' => 'g',
    's' || 'sensitive' => 's',
    'q' || 'questionable' => 'q',
    'e' || 'explicit' => 'e',
    _ => rating,
  };

  // Match literal text with `*` using bounded backtracking to the last star.
  // Unlike a generated regex with many .* groups, this cannot backtrack
  // exponentially on an imported rule containing many wildcards.
  static bool _wildcardMatches(String pattern, String tag) {
    var patternIndex = 0, tagIndex = 0, star = -1, retry = 0;
    while (tagIndex < tag.length) {
      if (patternIndex < pattern.length &&
          pattern.codeUnitAt(patternIndex) != 42 &&
          pattern.codeUnitAt(patternIndex) == tag.codeUnitAt(tagIndex)) {
        patternIndex++;
        tagIndex++;
      } else if (patternIndex < pattern.length &&
          pattern.codeUnitAt(patternIndex) == 42) {
        star = patternIndex++;
        retry = tagIndex;
      } else if (star != -1) {
        patternIndex = star + 1;
        tagIndex = ++retry;
      } else {
        return false;
      }
    }
    while (patternIndex < pattern.length &&
        pattern.codeUnitAt(patternIndex) == 42) {
      patternIndex++;
    }
    return patternIndex == pattern.length;
  }
}

class _BlacklistTerm {
  _BlacklistTerm(String term)
    : negative = term.startsWith('-'),
      value = term.startsWith('-') ? term.substring(1) : term;

  final bool negative;
  final String value;
}
