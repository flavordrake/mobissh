/**
 * test/infra/release-signing-toolchain.test.js
 *
 * #1277 (client side of homelab#44):
 * - A keyless release build is UNSIGNED: build.gradle.kts has no debug-keystore
 *   fallback for the release build type. The signer (local apksigner today, the
 *   isolated signer next) is the only thing that may sign a release APK.
 * - native/.flutter-version pins the SDK; CI installs that version and
 *   native-release-apk.sh refuses a release when the active toolchain differs.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const GRADLE = path.join(REPO_ROOT, 'native/android/app/build.gradle.kts');
const PIN = path.join(REPO_ROOT, 'native/.flutter-version');
const RELEASE = path.join(REPO_ROOT, 'scripts/native-release-apk.sh');

// The `release { ... }` block inside `buildTypes { ... }`, brace-matched.
function releaseBuildType(src) {
  const bt = src.indexOf('buildTypes {');
  assert.ok(bt >= 0, 'no buildTypes block');
  const start = src.indexOf('release {', bt);
  assert.ok(start >= 0, 'no release build type');
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error('unbalanced release block');
}

describe('#1277 keyless release builds are unsigned', () => {
  const src = fs.readFileSync(GRADLE, 'utf8');
  const code = src.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');

  it('the release build type never falls back to the debug signing config', () => {
    assert.doesNotMatch(releaseBuildType(code), /debug/i);
    assert.doesNotMatch(code, /signingConfigs\.getByName\("debug"\)/);
  });

  it('without key.properties the release signingConfig is null', () => {
    assert.match(releaseBuildType(code), /signingConfig\s*=\s*if\s*\(keystoreProperties\.isNotEmpty\(\)[^{]*\)\s*\{[^}]*signingConfigs\.getByName\("release"\)[^}]*\}\s*else\s*\{?\s*null/);
  });

  it('native-release-apk.sh still refuses to build without key.properties (#1215)', () => {
    assert.match(fs.readFileSync(RELEASE, 'utf8'), /if \[\[ ! -f "\$KEY_PROPS" \]\]; then/);
  });
});

describe('#1277 pinned Flutter SDK', () => {
  it('native/.flutter-version holds one exact x.y.z version', () => {
    assert.ok(fs.existsSync(PIN), `${PIN} missing`);
    assert.match(fs.readFileSync(PIN, 'utf8'), /^\d+\.\d+\.\d+\n?$/);
  });

  it('CI installs the pinned version', () => {
    const pin = fs.readFileSync(PIN, 'utf8').trim();
    const ci = fs.readFileSync(path.join(REPO_ROOT, '.github/workflows/ci.yml'), 'utf8');
    const m = /flutter-version:\s*'([^']+)'/.exec(ci);
    assert.ok(m, 'ci.yml pins no flutter-version');
    assert.equal(m[1], pin);
  });

  // Sandbox: the release script with a stub flutter-cmd.sh that reports
  // `activeVersion` for --version and fails `pub get`, so a run that passes the
  // toolchain check stops at the next step without building anything.
  function runRelease({ pin, activeVersion }) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tc1277-'));
    const w = (rel, body, mode) => {
      const p = path.join(root, rel);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, body);
      if (mode) fs.chmodSync(p, mode);
    };
    w('scripts/native-release-apk.sh', fs.readFileSync(RELEASE), 0o755);
    w('scripts/flutter-cmd.sh', [
      '#!/usr/bin/env bash',
      'ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
      'echo "$*" >> "$ROOT/flutter-calls.txt"',
      'if [[ " $* " == *" --version "* ]]; then',
      `  printf '{\\n  "frameworkVersion": "%s",\\n  "channel": "stable"\\n}\\n' '${activeVersion}'`,
      '  exit 0',
      'fi',
      'exit 65',
      '',
    ].join('\n'), 0o755);
    w('native/pubspec.yaml', 'name: mobissh\nversion: 0.1.13-dev+200\n');
    if (pin !== null) w('native/.flutter-version', `${pin}\n`);
    w('key.properties', 'storeFile=x\n');
    w('home/.mobissh/feedback.env', 'FEEDBACK_KEY=test-key\n'); // a keyless release is refused
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
    const callsFile = path.join(root, 'flutter-calls.txt');
    const calls = fs.existsSync(callsFile) ? fs.readFileSync(callsFile, 'utf8').trim().split('\n') : [];
    return { r, calls, out: r.stdout + r.stderr, published: fs.existsSync(path.join(root, 'dist')) };
  }

  it('refuses a release when the active Flutter differs from the pin', () => {
    const { r, calls, out, published } = runRelease({ pin: '3.44.0', activeVersion: '3.47.5' });
    assert.equal(r.status, 2, out);
    assert.match(out, /3\.47\.5/);
    assert.match(out, /3\.44\.0/);
    assert.ok(calls.every((c) => /--version/.test(c)), `ran past the check: ${calls.join(' | ')}`);
    assert.ok(!published, 'nothing may be published');
  });

  it('refuses a release when native/.flutter-version is missing', () => {
    const { r, calls, out } = runRelease({ pin: null, activeVersion: '3.44.0' });
    assert.equal(r.status, 2, out);
    assert.match(out, /\.flutter-version/);
    assert.ok(!calls.some((c) => /pub get|build apk/.test(c)), calls.join(' | '));
  });

  it('a matching toolchain passes the check and reaches the next step', () => {
    const { calls, out } = runRelease({ pin: '3.44.0', activeVersion: '3.44.0' });
    assert.match(out, /flutter 3\.44\.0 matches/i);
    assert.ok(calls.some((c) => /pub get --enforce-lockfile/.test(c)), calls.join(' | '));
  });
});
