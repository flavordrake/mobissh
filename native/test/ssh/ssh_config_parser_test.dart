// Unit tests for the pasted-ssh-config parser (profile-import goal).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_config_parser.dart';

void main() {
  group('parseSshConfig', () {
    test('parses a single full stanza', () {
      const cfg = '''
Host prod
  HostName prod.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519
''';
      final entries = parseSshConfig(cfg);
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.alias, 'prod');
      expect(e.hostName, 'prod.example.com');
      expect(e.effectiveHost, 'prod.example.com');
      expect(e.port, 2222);
      expect(e.user, 'deploy');
      expect(e.identityFile, '~/.ssh/id_ed25519');
      expect(e.isWildcard, isFalse);
    });

    test('effectiveHost falls back to the alias when HostName is absent', () {
      const cfg = 'Host 10.0.0.5\n  User root\n';
      final e = parseSshConfig(cfg).single;
      expect(e.hostName, isNull);
      expect(e.effectiveHost, '10.0.0.5');
      expect(e.user, 'root');
    });

    test('parses multiple stanzas in order', () {
      const cfg = '''
Host a
  HostName a.example.com
Host b
  HostName b.example.com
  Port 2022
''';
      final entries = parseSshConfig(cfg);
      expect(entries.map((e) => e.alias), ['a', 'b']);
      expect(entries[1].port, 2022);
    });

    test('accepts Keyword=value form and is case-insensitive', () {
      const cfg = 'HOST=prod\nhostname=prod.example.com\nPORT=2200\n';
      final e = parseSshConfig(cfg).single;
      expect(e.alias, 'prod');
      expect(e.hostName, 'prod.example.com');
      expect(e.port, 2200);
    });

    test('ignores comments, blank lines, and unsupported directives', () {
      const cfg = '''
# a comment
Host prod

  HostName prod.example.com
  ProxyJump bastion
  ForwardAgent yes
  User deploy
''';
      final e = parseSshConfig(cfg).single;
      expect(e.hostName, 'prod.example.com');
      expect(e.user, 'deploy');
    });

    test('ignores directives before the first Host line', () {
      const cfg = 'User globaldefault\nHost prod\n  HostName prod.example.com\n';
      final e = parseSshConfig(cfg).single;
      // The global User default is dropped — only in-stanza values import.
      expect(e.user, isNull);
      expect(e.hostName, 'prod.example.com');
    });

    test('Host with several patterns keys on the first; flags wildcards', () {
      const cfg = 'Host prod db\n  User deploy\nHost *\n  ForwardAgent yes\n';
      final entries = parseSshConfig(cfg);
      expect(entries[0].alias, 'prod');
      expect(entries[0].isWildcard, isFalse);
      expect(entries[1].alias, '*');
      expect(entries[1].isWildcard, isTrue);
    });

    test('strips surrounding quotes from a value', () {
      const cfg = 'Host prod\n  IdentityFile "~/.ssh/my key"\n';
      expect(parseSshConfig(cfg).single.identityFile, '~/.ssh/my key');
    });

    test('takes the first IdentityFile when the directive repeats', () {
      const cfg =
          'Host prod\n  IdentityFile ~/.ssh/a\n  IdentityFile ~/.ssh/b\n';
      expect(parseSshConfig(cfg).single.identityFile, '~/.ssh/a');
    });

    test('invalid port is dropped, not thrown', () {
      const cfg = 'Host prod\n  Port not-a-number\n';
      expect(parseSshConfig(cfg).single.port, isNull);
    });

    test('empty input yields no entries', () {
      expect(parseSshConfig(''), isEmpty);
      expect(parseSshConfig('\n\n# only a comment\n'), isEmpty);
    });
  });
}
