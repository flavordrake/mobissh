// A10 (#1185, slice 3 of #1182): export saved profiles AS `~/.ssh/config` text.
//
// R21 stanza generation, R22 no secret is EVER written, R24 round-trip back
// through the real parser. The R22 test comes first and deliberately uses a
// profile whose secrets are ACTUALLY stored (a password AND a private key in a
// SecretsStore) — asserting the secret strings appear nowhere in the output,
// not merely that a field was skipped.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_config_export.dart';
import 'package:mobissh/ssh/ssh_config_parser.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

const String kPassword = 'hunter2-DO-NOT-EXPORT';
const String kPrivateKey =
    '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAsecretmaterial\n'
    '-----END OPENSSH PRIVATE KEY-----';
const String kPassphrase = 'passphrase-DO-NOT-EXPORT';

SavedProfile _profile({
  String title = 'Prod',
  String host = 'prod.example.com',
  int port = 22,
  String username = 'deploy',
  String? authType,
  String? vaultId,
  String? keyVaultId,
  String? linkAlias,
  String? jumpIdentityKey,
}) =>
    SavedProfile(
      title: title,
      host: host,
      port: port,
      username: username,
      authType: authType,
      vaultId: vaultId,
      keyVaultId: keyVaultId,
      linkAlias: linkAlias,
      jumpIdentityKey: jumpIdentityKey,
    );

void main() {
  group('R22 — no secret is ever written', () {
    test('a profile with a STORED password and key exports neither', () async {
      final backend = InMemorySecretsBackend();
      final secrets = SecretsStore(backend: backend);
      final profile = _profile(
        authType: 'key',
        vaultId: 'profile-prod',
        keyVaultId: 'key-abc',
      );
      // The secrets really exist for this profile.
      await secrets.write('profile-prod', {
        'password': kPassword,
        'privateKey': kPrivateKey,
        'passphrase': kPassphrase,
      });
      await secrets.write('key-abc', {
        'privateKey': kPrivateKey,
        'passphrase': kPassphrase,
      });
      expect(await secrets.read('profile-prod'), isNotNull);

      final export = buildSshConfigExport([profile]);

      expect(export.text.contains(kPassword), isFalse);
      expect(export.text.contains(kPrivateKey), isFalse);
      expect(export.text.contains(kPassphrase), isFalse);
      expect(export.text.contains('BEGIN OPENSSH PRIVATE KEY'), isFalse);
      // The vault references are not secrets, but they are not ssh_config
      // either — nothing about the vault leaks into the artifact.
      expect(export.text.contains('profile-prod'), isFalse);
      expect(export.text.contains('key-abc'), isFalse);
    });

    test('key auth with no path-like hint omits IdentityFile and NAMES the '
        'profile as needing a key configured by hand', () {
      final profile = _profile(authType: 'key', keyVaultId: 'key-abc');
      final export = buildSshConfigExport([profile]);

      expect(export.text.contains('IdentityFile'), isFalse);
      expect(export.needsManualKey, ['prod']);
      // The artifact itself says so — an export that looks complete but cannot
      // authenticate is the failure mode this slice exists to avoid.
      expect(export.text.contains('prod'), isTrue);
      expect(
        export.text.toLowerCase().contains('key'),
        isTrue,
        reason: 'the header must name the hosts needing a manual key',
      );
    });

    test('key auth WITH a path-like library-key name emits the hint only', () {
      final profile = _profile(authType: 'key', keyVaultId: 'key-abc');
      final key = SavedKey(id: 'abc', name: '~/.ssh/id_ed25519');
      final export = buildSshConfigExport([profile], keys: [key]);

      expect(export.text.contains('IdentityFile ~/.ssh/id_ed25519'), isTrue);
      expect(export.needsManualKey, isEmpty);
    });

    test('a library key whose name is NOT path-like is not a hint', () {
      final profile = _profile(authType: 'key', keyVaultId: 'key-abc');
      final key = SavedKey(id: 'abc', name: 'work laptop');
      final export = buildSshConfigExport([profile], keys: [key]);

      expect(export.text.contains('IdentityFile'), isFalse);
      expect(export.text.contains('work laptop'), isFalse);
      expect(export.needsManualKey, ['prod']);
    });
  });

  group('R21 — stanza generation', () {
    test('default port and empty user are omitted', () {
      final export = buildSshConfigExport([
        _profile(title: 'Plain', host: 'plain.example.com', username: ''),
      ]);
      expect(export.text.contains('Host plain'), isTrue);
      expect(export.text.contains('HostName plain.example.com'), isTrue);
      expect(export.text.contains('Port'), isFalse);
      expect(export.text.contains('User'), isFalse);
    });

    test('non-default port and a user are emitted', () {
      final export = buildSshConfigExport([
        _profile(title: 'Prod', port: 2222, username: 'deploy'),
      ]);
      expect(export.text.contains('Port 2222'), isTrue);
      expect(export.text.contains('User deploy'), isTrue);
    });

    test('a jump host renders ProxyJump with the HOP alias', () {
      final bastion = _profile(
        title: 'Bastion',
        host: 'edge.example.com',
        username: 'jump',
      );
      final target = _profile(
        title: 'Prod',
        jumpIdentityKey: bastion.identityKey,
      );
      final export = buildSshConfigExport([bastion, target]);

      expect(export.text.contains('ProxyJump bastion'), isTrue);
      expect(export.unresolvedJumps, isEmpty);
      // The hop's own stanza carries no ProxyJump.
      final entries = parseSshConfig(export.text);
      expect(entries.first.alias, 'bastion');
      expect(entries.first.proxyJump, isEmpty);
    });

    test('no jump host renders no ProxyJump', () {
      final export = buildSshConfigExport([_profile()]);
      expect(export.text.contains('ProxyJump'), isFalse);
    });

    test('a jump host outside the exported set is omitted and reported', () {
      final target = _profile(jumpIdentityKey: 'edge.example.com:22:jump');
      final export = buildSshConfigExport([target]);

      // No ProxyJump DIRECTIVE (the header still says the hop was dropped —
      // silently losing the link is the failure mode).
      expect(parseSshConfig(export.text).single.proxyJump, isEmpty);
      expect(export.unresolvedJumps, ['prod']);
      expect(export.text.contains('# Jump host not included'), isTrue);
    });
  });

  group('alias choice', () {
    test('linkAlias wins over a slug derived from the title', () {
      final export = buildSshConfigExport([
        _profile(title: 'Prod box', linkAlias: 'prodbox'),
      ]);
      expect(export.text.contains('Host prodbox'), isTrue);
    });

    test('a title slug satisfies ssh Host token rules', () {
      final export = buildSshConfigExport([
        _profile(title: 'Prod box #1 (eu)', host: 'a.example.com'),
      ]);
      final alias = parseSshConfig(export.text).single.alias;
      expect(RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(alias), isTrue);
      expect(alias.contains('*'), isFalse);
      expect(alias.contains('?'), isFalse);
    });

    test('colliding titles yield distinct Host tokens', () {
      final export = buildSshConfigExport([
        _profile(title: 'Prod', host: 'a.example.com'),
        _profile(title: 'Prod', host: 'b.example.com'),
        _profile(title: 'Prod', host: 'c.example.com'),
      ]);
      final aliases = parseSshConfig(export.text).map((e) => e.alias).toList();
      expect(aliases, hasLength(3));
      expect(aliases.toSet(), hasLength(3));
    });

    test('a title with no usable characters falls back to the host', () {
      final export = buildSshConfigExport([
        _profile(title: '###', host: 'fallback.example.com'),
      ]);
      final alias = parseSshConfig(export.text).single.alias;
      expect(alias, 'fallback.example.com');
    });
  });

  group('R24 — round-trip through the real parser', () {
    test('re-importing the export yields the same profiles and jump links', () {
      final bastion = _profile(
        title: 'Bastion',
        host: 'edge.example.com',
        port: 2022,
        username: 'jump',
      );
      final target = _profile(
        title: 'Prod',
        host: 'prod.example.com',
        port: 2222,
        username: 'deploy',
        jumpIdentityKey: bastion.identityKey,
      );
      final plain = _profile(
        title: 'Plain',
        host: 'plain.example.com',
        username: 'root',
      );
      final profiles = [bastion, target, plain];

      final export = buildSshConfigExport(profiles);
      final entries = parseSshConfig(export.text);

      expect(entries, hasLength(3));
      // Same set of profiles: host, port (22 when the directive is omitted)
      // and user survive.
      final byAlias = {for (final e in entries) e.alias: e};
      for (final p in profiles) {
        final alias = export.aliasByIdentityKey[p.identityKey]!;
        final e = byAlias[alias]!;
        expect(e.effectiveHost, p.host);
        expect(e.port ?? 22, p.port);
        expect(e.user ?? '', p.username);
      }

      // Same jump links: the target's ProxyJump alias resolves back to the
      // bastion's identity.
      final targetEntry = byAlias[export.aliasByIdentityKey[target.identityKey]]!;
      expect(targetEntry.proxyJump, hasLength(1));
      final identityByAlias = {
        for (final entry in export.aliasByIdentityKey.entries)
          entry.value: entry.key,
      };
      // The parser (#1184) models a hop as SshJumpHop; an exported ProxyJump is
      // a bare alias, so the alias token is the hop's host.
      final hop = targetEntry.proxyJump.single;
      expect(hop.isBareAlias, isTrue);
      expect(identityByAlias[hop.host], bastion.identityKey);
      expect(
        byAlias[export.aliasByIdentityKey[bastion.identityKey]]!.proxyJump,
        isEmpty,
      );
      expect(
        byAlias[export.aliasByIdentityKey[plain.identityKey]]!.proxyJump,
        isEmpty,
      );
    });

    test('an empty profile set still round-trips (no stanzas)', () {
      final export = buildSshConfigExport(const []);
      expect(parseSshConfig(export.text), isEmpty);
    });
  });
}
