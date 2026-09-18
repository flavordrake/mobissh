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

  // A9 (#1184, spec docs/jump-host.md R17/R19/R20): ProxyJump is no longer an
  // ignored directive — it parses into an ORDERED list of hop specs.
  group('parseSshConfig — ProxyJump (R17/R19/R20)', () {
    test('R17: a bare alias hop', () {
      const cfg = 'Host prod\n  HostName prod.example.com\n'
          '  ProxyJump bastion\n';
      final e = parseSshConfig(cfg).single;
      expect(e.proxyJump, hasLength(1));
      final hop = e.proxyJump.single;
      expect(hop.host, 'bastion');
      expect(hop.user, isNull);
      expect(hop.port, isNull);
      expect(hop.isBareAlias, isTrue);
      expect(hop.spec, 'bastion');
    });

    test('R17: a literal user@host:port hop', () {
      const cfg =
          'Host prod\n  ProxyJump jumpuser@bastion.example.com:2222\n';
      final hop = parseSshConfig(cfg).single.proxyJump.single;
      expect(hop.user, 'jumpuser');
      expect(hop.host, 'bastion.example.com');
      expect(hop.port, 2222);
      expect(hop.isBareAlias, isFalse);
      expect(hop.spec, 'jumpuser@bastion.example.com:2222');
    });

    test('R20: a comma-separated chain keeps ssh order (outermost first)', () {
      const cfg = 'Host prod\n  ProxyJump a, me@b.example.com:2022 ,c\n';
      final hops = parseSshConfig(cfg).single.proxyJump;
      expect(hops.map((h) => h.host), ['a', 'b.example.com', 'c']);
      expect(hops[1].user, 'me');
      expect(hops[1].port, 2022);
    });

    test('R19: legacy ProxyCommand ssh -W %h:%p maps to a hop', () {
      const cfg = 'Host prod\n  ProxyCommand ssh -W %h:%p bastion\n';
      final e = parseSshConfig(cfg).single;
      expect(e.proxyJump.single.host, 'bastion');
      expect(e.proxyCommandNote, isNull);
    });

    test('R19: legacy form carries -p / -l onto the hop', () {
      const cfg =
          'Host prod\n  ProxyCommand ssh -q -W %h:%p -p 2222 -l ops jump.example.com\n';
      final hop = parseSshConfig(cfg).single.proxyJump.single;
      expect(hop.host, 'jump.example.com');
      expect(hop.port, 2222);
      expect(hop.user, 'ops');
    });

    test('R19: any OTHER ProxyCommand is ignored WITH a named reason', () {
      const cfg = 'Host prod\n  ProxyCommand nc -X 5 -x proxy:1080 %h %p\n';
      final e = parseSshConfig(cfg).single;
      expect(e.proxyJump, isEmpty);
      expect(e.proxyCommandNote, isNotNull);
      // Names the directive AND the value, so the user can see what was
      // dropped — a silent drop yields a profile that connects differently.
      expect(e.proxyCommandNote, contains('ProxyCommand'));
      expect(e.proxyCommandNote, contains('nc -X 5 -x proxy:1080 %h %p'));
    });

    test('R17: a malformed ProxyJump value is ignored, never thrown', () {
      for (final bad in <String>[
        'Host prod\n  ProxyJump user@\n',
        'Host prod\n  ProxyJump ,,\n',
        'Host prod\n  ProxyJump host:not-a-port\n',
        'Host prod\n  ProxyJump @host\n',
      ]) {
        late List<SshConfigEntry> entries;
        expect(() => entries = parseSshConfig(bad), returnsNormally);
        expect(entries.single.proxyJump, isEmpty, reason: bad);
      }
    });

    test('R17: ProxyJump none means no jump host (ssh semantics)', () {
      const cfg = 'Host prod\n  ProxyJump none\n';
      expect(parseSshConfig(cfg).single.proxyJump, isEmpty);
    });

    test('R19: an explicit ProxyJump wins over a legacy ProxyCommand', () {
      const cfg = 'Host prod\n  ProxyCommand ssh -W %h:%p old\n'
          '  ProxyJump new\n';
      final e = parseSshConfig(cfg).single;
      expect(e.proxyJump.map((h) => h.host), ['new']);
      expect(e.proxyCommandNote, isNull);
    });

    test('hops do not leak across stanzas', () {
      const cfg = 'Host a\n  ProxyJump bastion\nHost b\n  HostName b.example\n';
      final entries = parseSshConfig(cfg);
      expect(entries[0].proxyJump, hasLength(1));
      expect(entries[1].proxyJump, isEmpty);
    });
  });

  group('formatSshConfig', () {
    test('renders a full stanza', () {
      final block = formatSshConfig(
        alias: 'prod',
        host: 'prod.example.com',
        port: 2222,
        user: 'deploy',
        identityFile: '~/.ssh/id_ed25519',
      );
      expect(
        block,
        'Host prod\n'
        '  HostName prod.example.com\n'
        '  Port 2222\n'
        '  User deploy\n'
        '  IdentityFile ~/.ssh/id_ed25519\n',
      );
    });

    test('omits the default port, empty user, and absent IdentityFile', () {
      final block = formatSshConfig(alias: 'box', host: 'box.example.com');
      expect(block, 'Host box\n  HostName box.example.com\n');
    });

    test('omits User when only whitespace', () {
      final block = formatSshConfig(
        alias: 'box',
        host: 'box.example.com',
        user: '   ',
      );
      expect(block.contains('User'), isFalse);
    });

    test('round-trips through parseSshConfig', () {
      final block = formatSshConfig(
        alias: 'prod',
        host: 'prod.example.com',
        port: 2222,
        user: 'deploy',
        identityFile: '~/.ssh/id_ed25519',
      );
      final e = parseSshConfig(block).single;
      expect(e.alias, 'prod');
      expect(e.effectiveHost, 'prod.example.com');
      expect(e.port, 2222);
      expect(e.user, 'deploy');
      expect(e.identityFile, '~/.ssh/id_ed25519');
    });

    test('default-port round-trip restores 22 (Port omitted → parser null)', () {
      final block = formatSshConfig(
        alias: 'box',
        host: 'box.example.com',
        user: 'me',
      );
      final e = parseSshConfig(block).single;
      expect(e.port, isNull); // absent Port; the editor defaults it to 22
      expect(e.user, 'me');
    });
  });
}
