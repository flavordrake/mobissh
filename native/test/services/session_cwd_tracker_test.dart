// SessionCwdTracker unit tests (#1036) — the per-session cwd ladder that
// resolves RELATIVE detected paths to absolutes for the #990 verifier.
//
// Ladder: OSC 7 (controller.pwd advisory) > prompt-derived (#998 strong
// `user@host:PATH$` shape) > last-known (both sources are sticky) > home.
// "Home" is represented as `~` UI-side — the task-side SFTP layer (#867
// expandTilde) expands it at the single seam every stat/list routes through,
// so no realpath IPC is needed. Staleness is tolerated by design: the #990
// verifier absorbs a wrong cwd (the resolved path just never verifies).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_cwd_tracker.dart';

void main() {
  group('osc7Cwd — OSC 7 advisory parsing', () {
    test('file:// URI with host → path', () {
      expect(osc7Cwd('file://myhost/tmp/work'), '/tmp/work');
    });

    test('file:// URI without host → path', () {
      expect(osc7Cwd('file:///tmp/work'), '/tmp/work');
    });

    test('bare absolute path passes through', () {
      expect(osc7Cwd('/home/user/x'), '/home/user/x');
    });

    test('percent-encoded path decodes', () {
      expect(osc7Cwd('file://h/tmp/a%20b'), '/tmp/a b');
    });

    test('empty / non-path values → null (unset)', () {
      expect(osc7Cwd(''), isNull);
      expect(osc7Cwd('   '), isNull);
      expect(osc7Cwd('not-a-path'), isNull);
      // A malformed file URI must not crash — null, not throw.
      expect(osc7Cwd('file://%ZZ'), isNull);
    });
  });

  group('promptCwd — #998 strong-prompt PATH extraction', () {
    test('user@host:absolute-path\$ shape', () {
      expect(promptCwd(r'dev@fd-dev:/tmp/work$ echo hi'), '/tmp/work');
    });

    test('user@host:~\$ home shape', () {
      expect(promptCwd(r'dev@fd-dev:~$ '), '~');
    });

    test('user@host:~/sub\$ shape', () {
      expect(promptCwd(r'dev@fd-dev:~/sub$ ls'), '~/sub');
    });

    test('root # prompt', () {
      expect(promptCwd('root@box:/etc# '), '/etc');
    });

    test('non-prompt lines → null', () {
      expect(promptCwd('just some output'), isNull);
      expect(promptCwd(r'$ echo weak-prompt'), isNull);
      // A weak `user@host` without the :path$ tail is not a strong prompt.
      expect(promptCwd('mail user@host.com please'), isNull);
    });

    test('mid-line prompt does not extract (anchored at line start)', () {
      expect(promptCwd(r'echo dev@fd-dev:/tmp$ fake'), isNull);
    });
  });

  group('resolveRelativePath — join + normalize', () {
    test('plain join', () {
      expect(resolveRelativePath('/tmp/work', 'sub/real.txt'),
          '/tmp/work/sub/real.txt');
    });

    test('trailing-slash cwd joins without doubling', () {
      expect(resolveRelativePath('/tmp/', 'a/b'), '/tmp/a/b');
    });

    test('root cwd', () {
      expect(resolveRelativePath('/', 'a/b'), '/a/b');
    });

    test('dot segments normalize', () {
      expect(resolveRelativePath('/tmp/work', 'a/./b'), '/tmp/work/a/b');
      expect(resolveRelativePath('/tmp/work', 'a/../b'), '/tmp/work/b');
    });

    test('.. never pops past root', () {
      expect(resolveRelativePath('/', 'a/../../b'), '/b');
    });

    test('~ cwd resolves under home (expanded task-side, #867)', () {
      expect(resolveRelativePath('~', 'a/b'), '~/a/b');
      expect(resolveRelativePath('~/sub', 'x/y.md'), '~/sub/x/y.md');
    });

    test('.. never pops the ~ home marker itself', () {
      expect(resolveRelativePath('~', 'a/../../b'), '~/b');
    });

    test('trailing slash on the relative is preserved', () {
      expect(resolveRelativePath('/tmp', 'src/util/'), '/tmp/src/util/');
    });
  });

  group('SessionCwdTracker — ladder precedence + isolation', () {
    test('defaults to home (~) before any evidence', () {
      final t = SessionCwdTracker();
      expect(t.cwd, '~');
      expect(t.resolve('a/b'), '~/a/b');
    });

    test('prompt-derived cwd beats home', () {
      final t = SessionCwdTracker();
      t.notePromptLine(r'dev@fd-dev:/tmp/work$ ');
      expect(t.cwd, '/tmp/work');
      expect(t.resolve('sub/real.txt'), '/tmp/work/sub/real.txt');
    });

    test('OSC 7 beats prompt-derived', () {
      final t = SessionCwdTracker();
      t.notePromptLine(r'dev@fd-dev:/from-prompt$ ');
      t.noteOsc7('file://h/from-osc7');
      expect(t.cwd, '/from-osc7');
    });

    test('sources are sticky (last-known survives non-prompt output)', () {
      final t = SessionCwdTracker();
      t.notePromptLine(r'dev@fd-dev:/tmp/work$ ');
      t.notePromptLine('plain output, no prompt'); // must not clear
      expect(t.cwd, '/tmp/work');
    });

    test('a fresh prompt replaces the previous prompt cwd', () {
      final t = SessionCwdTracker();
      t.notePromptLine(r'dev@fd-dev:/a$ ');
      t.notePromptLine(r'dev@fd-dev:/b$ ');
      expect(t.cwd, '/b');
    });

    test('an EMPTY OSC 7 does not clobber a seen advisory', () {
      final t = SessionCwdTracker();
      t.noteOsc7('file://h/keep');
      t.noteOsc7('');
      expect(t.cwd, '/keep');
    });

    test('per-session isolation: trackers never share state', () {
      final a = SessionCwdTracker();
      final b = SessionCwdTracker();
      a.notePromptLine(r'dev@a:/only-a$ ');
      expect(a.cwd, '/only-a');
      expect(b.cwd, '~');
    });

    test('noteOsc7/notePromptLine report whether the cwd changed', () {
      final t = SessionCwdTracker();
      expect(t.notePromptLine(r'dev@h:/x$ '), isTrue);
      expect(t.notePromptLine(r'dev@h:/x$ '), isFalse); // unchanged
      expect(t.noteOsc7('file://h/y'), isTrue);
      expect(t.noteOsc7('file://h/y'), isFalse);
      expect(t.notePromptLine('no prompt here'), isFalse);
    });
  });
}
