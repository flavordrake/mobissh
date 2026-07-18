// #493 — favorites submenu shows full redundant path prefixes. When several
// unlabeled bookmarks share a common parent (e.g. all under
// `/home/dev/workspace/`), the divergent leaf — the part the user reads — gets
// buried at the right edge. This pure display layer collapses the shared prefix
// to `…/` so only the distinguishing suffix renders.
//
// Comparison is SEGMENT-WISE (split on `/`) so `/home/dev` is never treated as
// a prefix of `/home/develop`. The collapse stops one segment short of the
// shortest path so a single common-parent set still shows distinguishable
// leaves.

import 'dart:math';

/// Segment-wise common leading segments across [paths] (each path split on
/// `/`, empty segments — including the leading one for absolute paths — kept so
/// comparison never splits mid-segment). Returns an empty list for fewer than
/// two paths (nothing to collapse against).
List<String> commonPathPrefix(List<String> paths) {
  if (paths.length < 2) return const <String>[];
  final segLists = paths.map((p) => p.split('/')).toList();
  final minLen = segLists.map((s) => s.length).reduce(min);
  final common = <String>[];
  for (var i = 0; i < minLen; i++) {
    final seg = segLists.first[i];
    if (segLists.every((s) => s[i] == seg)) {
      common.add(seg);
    } else {
      break;
    }
  }
  return common;
}

/// Display strings for [paths], aligned by index, with the shared leading
/// directory prefix replaced by `…/`. The cut stops one segment short of the
/// shortest path. Paths are returned unchanged when there are fewer than two,
/// or when the shared prefix hides no real (non-empty) segment — e.g. two
/// unrelated absolute paths share only the empty root segment.
List<String> collapsePrefix(List<String> paths) {
  if (paths.length < 2) return List<String>.of(paths);
  final segLists = paths.map((p) => p.split('/')).toList();
  final shortest = segLists.map((s) => s.length).reduce(min);
  var cut = commonPathPrefix(paths).length;
  if (cut >= shortest) cut = shortest - 1; // stop one short of the shortest
  // Only collapse when the hidden prefix contains at least one real segment —
  // otherwise we'd replace nothing meaningful (or just the root) with `…`.
  final hidesRealSegment = segLists.first.take(cut).any((s) => s.isNotEmpty);
  if (!hidesRealSegment) return List<String>.of(paths);
  return [for (final segs in segLists) '…/${segs.sublist(cut).join('/')}'];
}
