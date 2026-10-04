/**
 * test/infra/dependency-verification.test.js
 *
 * #1277 (verified inputs): release builds only compile pinned dependencies.
 * - Gradle: native/android/gradle/verification-metadata.xml exists, verifies
 *   metadata, pins sha256 for the Flutter engine artifacts and the Android
 *   Gradle plugin, and gradle.properties sets strict verification.
 * - Dart: scripts/native-release-apk.sh runs `pub get --enforce-lockfile`
 *   before `build apk`, and a failing lockfile check exits 2 before any build.
 * - pubspec.lock pins a sha256 for every hosted package.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const ANDROID = path.join(REPO_ROOT, 'native/android');
const METADATA = path.join(ANDROID, 'gradle/verification-metadata.xml');
const RELEASE = path.join(REPO_ROOT, 'scripts/native-release-apk.sh');

describe('#1277 Gradle dependency verification', () => {
  it('verification-metadata.xml exists and verifies metadata', () => {
    assert.ok(fs.existsSync(METADATA), `${METADATA} missing`);
    const xml = fs.readFileSync(METADATA, 'utf8');
    assert.match(xml, /<verify-metadata>true<\/verify-metadata>/);
  });

  it('pins sha256 for the Flutter engine artifacts and the Android Gradle plugin', () => {
    const xml = fs.readFileSync(METADATA, 'utf8');
    for (const name of ['flutter_embedding_release', 'arm64_v8a_release']) {
      const re = new RegExp(`<component group="io\\.flutter" name="${name}"[^]*?<sha256 value="[0-9a-f]{64}"`);
      assert.match(xml, re, `io.flutter:${name} not pinned`);
    }
    assert.match(xml, /<component group="com\.android\.tools\.build" name="gradle" version="9\.0\.1">[^]*?<sha256 value="[0-9a-f]{64}"/);
  });

  it('gradle.properties enforces strict verification', () => {
    const props = fs.readFileSync(path.join(ANDROID, 'gradle.properties'), 'utf8');
    assert.match(props, /^org\.gradle\.dependency\.verification=strict$/m);
    assert.doesNotMatch(props, /dependency\.verification=(lenient|off)/);
  });

  it('declares no plain-HTTP repository', () => {
    for (const f of ['settings.gradle.kts', 'build.gradle.kts', 'app/build.gradle.kts']) {
      const src = fs.readFileSync(path.join(ANDROID, f), 'utf8');
      assert.doesNotMatch(src, /http:\/\//, `${f} names an http:// URL`);
      assert.doesNotMatch(src, /allowInsecureProtocol/, `${f} allows insecure protocol`);
    }
  });
});

describe('#1277 Dart lockfile enforcement', () => {
  it('pubspec.lock has a sha256 for every hosted package', () => {
    const lock = fs.readFileSync(path.join(REPO_ROOT, 'native/pubspec.lock'), 'utf8');
    const entries = lock.split(/\n {2}(?=\S)/).slice(1);
    const hosted = entries.filter((e) => /source: hosted/.test(e));
    assert.ok(hosted.length > 0);
    const missing = hosted.filter((e) => !/sha256: "?[0-9a-f]{64}"?$/m.test(e)).map((e) => e.split(':')[0]);
    assert.deepEqual(missing, []);
  });

  it('native-release-apk.sh runs pub get --enforce-lockfile before build apk', () => {
    // The invocation lines, not the header comments that also name them.
    const lines = fs.readFileSync(RELEASE, 'utf8').split('\n');
    const call = (re) => lines.findIndex((l) => /flutter-cmd\.sh"/.test(l) && re.test(l));
    const pub = call(/pub get --enforce-lockfile/);
    const build = call(/build apk --release/);
    assert.ok(pub > 0, 'no pub get --enforce-lockfile in native-release-apk.sh');
    assert.ok(pub < build, 'lockfile check must run before the release build');
  });

  it('a failing lockfile check exits 2 before any build', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'deps1277-'));
    const w = (rel, body, mode) => {
      const p = path.join(root, rel);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, body);
      if (mode) fs.chmodSync(p, mode);
    };
    w('scripts/native-release-apk.sh', fs.readFileSync(RELEASE), 0o755);
    // Stub: logs each call; `pub get` fails as a hash mismatch would.
    w('scripts/flutter-cmd.sh', [
      '#!/usr/bin/env bash',
      'ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
      'echo "$*" >> "$ROOT/flutter-calls.txt"',
      'if [[ "$3" == pub ]]; then exit 65; fi',
      '',
    ].join('\n'), 0o755);
    w('native/pubspec.yaml', 'name: mobissh\nversion: 0.1.13-dev+200\n');
    w('key.properties', 'storeFile=x\n');
    w('home/.keep', '');
    const git = (...a) => execFileSync('git', ['-C', root, ...a], { stdio: 'ignore' });
    git('init', '-q');
    git('add', '-A');
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'sandbox');

    const r = spawnSync('bash', [path.join(root, 'scripts/native-release-apk.sh')], {
      encoding: 'utf8',
      env: {
        PATH: process.env.PATH,
        HOME: path.join(root, 'home'),
        MOBISSH_TMPDIR: path.join(root, 'tmp'),
        MOBISSH_LOGDIR: path.join(root, 'logs'),
        NATIVE_DIST_HOST: path.join(root, 'dist'),
        MOBISSH_KEY_PROPERTIES: path.join(root, 'key.properties'),
      },
    });
    assert.equal(r.status, 2, r.stdout + r.stderr);
    const calls = fs.readFileSync(path.join(root, 'flutter-calls.txt'), 'utf8').trim().split('\n');
    assert.equal(calls.length, 1, calls.join(' | '));
    assert.match(calls[0], /pub get --enforce-lockfile$/);
    assert.ok(!fs.existsSync(path.join(root, 'dist')), 'nothing may be published');
  });
});
