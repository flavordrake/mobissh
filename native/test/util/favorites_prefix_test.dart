// #493 — favorites submenu shows full redundant path prefixes. Pure display
// logic: when 2+ unlabeled favorites share a path-segment-wise common prefix,
// collapse the prefix to `…/` so only the distinguishing suffix renders.
//
// commonPathPrefix: segment-wise common leading segments across paths.
// collapsePrefix: aligned display strings with the shared prefix replaced by
// `…/`, stopping one segment short of the shortest path.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/util/favorites_prefix.dart';

void main() {
  group('#493 commonPathPrefix', () {
    test('shared leaf set — returns the common leading segments', () {
      expect(
        commonPathPrefix([
          '/home/dev/workspace/mobissh',
          '/home/dev/workspace/cuda',
          '/home/dev/workspace/devloop',
        ]),
        ['', 'home', 'dev', 'workspace'],
      );
    });

    test('single item — no common prefix (nothing to collapse against)', () {
      expect(commonPathPrefix(['/home/dev/workspace/mobissh']), isEmpty);
    });

    test('no shared prefix beyond root', () {
      expect(commonPathPrefix(['/var/log', '/etc/hosts']), ['']);
    });

    test('mid-segment safety — /home/dev is not a prefix of /home/develop', () {
      expect(
        commonPathPrefix(['/home/dev/x', '/home/develop/y']),
        ['', 'home'],
      );
    });
  });

  group('#493 collapsePrefix', () {
    test('shared leaf set collapses to the divergent leaf', () {
      expect(
        collapsePrefix([
          '/home/dev/workspace/mobissh',
          '/home/dev/workspace/cuda',
          '/home/dev/workspace/devloop',
        ]),
        ['…/mobissh', '…/cuda', '…/devloop'],
      );
    });

    test('stops one segment short of the shortest path', () {
      // Common prefix equals the shortest path (/home/dev/workspace). Collapse
      // must stop one short so the common-parent leaf still shows.
      expect(
        collapsePrefix([
          '/home/dev/workspace',
          '/home/dev/workspace/mobissh',
        ]),
        ['…/workspace', '…/workspace/mobissh'],
      );
    });

    test('single item — unchanged', () {
      expect(
        collapsePrefix(['/home/dev/workspace/mobissh']),
        ['/home/dev/workspace/mobissh'],
      );
    });

    test('no shared prefix beyond root — unchanged', () {
      expect(
        collapsePrefix(['/var/log', '/etc/hosts']),
        ['/var/log', '/etc/hosts'],
      );
    });

    test('mid-segment safety — dev and develop are not merged', () {
      expect(
        collapsePrefix(['/home/dev/x', '/home/develop/y']),
        ['…/dev/x', '…/develop/y'],
      );
    });
  });
}
