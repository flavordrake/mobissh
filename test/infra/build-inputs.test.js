/**
 * test/infra/build-inputs.test.js
 *
 * #1277 (homelab#44 follow-up): the feedback key reaches the release build only
 * through --dart-define-from-file, never on a command line or in a log.
 * scripts/native-release-apk.sh stages a private 0600 JSON inside native/ (the
 * buildbox snapshot carries native/, not /tmp) from MOBISSH_BUILD_INPUTS or the
 * legacy ~/.mobissh/feedback.env, passes it by relative path and deletes it
 * after the build. A missing key FAILS CLOSED; MOBISSH_ALLOW_NO_FEEDBACK_KEY=1
 * opts out for -dev builds only.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const RELEASE = path.join(REPO_ROOT, 'scripts/native-release-apk.sh');
const PIN = fs.readFileSync(path.join(REPO_ROOT, 'native/.flutter-version'), 'utf8').trim();
const KEY = 'FBKEY-SECRET-1277-q9Zx';
const RC = '0.1.13-rc.1+202';
const DEV = '0.1.14-dev+203';

function sandbox(version) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bi1277-'));
  const w = (rel, body, mode) => {
    const p = path.join(root, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, body);
    if (mode) fs.chmodSync(p, mode);
  };
  w('scripts/native-release-apk.sh', fs.readFileSync(RELEASE), 0o755);
  for (const s of ['gen-android-latest-json.sh', 'release-notes-top.sh']) {
    w(`scripts/${s}`, fs.readFileSync(path.join(REPO_ROOT, 'scripts', s)), 0o755);
  }
  // Stub: honours --in like the real wrapper, captures whatever file
  // --dart-define-from-file names (content + mode), then fakes the APK.
  w('scripts/flutter-cmd.sh', [
    '#!/usr/bin/env bash',
    `if [[ "$1" == --version ]]; then echo '"frameworkVersion": "${PIN}"'; exit 0; fi`,
    'ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
    'if [[ "$1" == --in ]]; then cd "$2"; shift 2; fi',
    'if [[ "$1" == pub ]]; then exit 0; fi',
    'printf "%s\\n" "$@" > "$ROOT/flutter-args.txt"',
    'for a in "$@"; do',
    '  case "$a" in --dart-define-from-file=*)',
    '    f="${a#--dart-define-from-file=}"',
    '    cp "$f" "$ROOT/captured-inputs.json"',
    '    stat -c %a "$f" > "$ROOT/captured-mode.txt" ;;',
    '  esac',
    'done',
    'if [[ -n "${STUB_BUILD_FAIL:-}" ]]; then exit 1; fi',
    'OUT="$ROOT/native/build/app/outputs/flutter-apk"',
    'mkdir -p "$OUT"',
    'printf "arm64 apk" > "$OUT/app-arm64-v8a-release.apk"',
    '',
  ].join('\n'), 0o755);
  w('scripts/gen-apk-install-page.sh',
    '#!/usr/bin/env bash\nROOT="$(cd "$(dirname "$0")/.." && pwd)"\necho page > "$ROOT/public/native.html"\n', 0o755);
  w('scripts/notify-build.sh', '#!/usr/bin/env bash\nexit 0\n', 0o755);
  w('native/pubspec.yaml', `name: mobissh\nversion: ${version}\n`);
  w('native/.flutter-version', `${PIN}\n`);
  w('public/native-time.js', '//');
  w('public/native-feedback.js', '//');
  w('key.properties', 'storeFile=x\n');
  w('home/.keep', '');
  const git = (...a) => execFileSync('git', ['-C', root, ...a], { stdio: 'ignore' });
  git('init', '-q');
  git('add', '-A');
  git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'sandbox');
  return root;
}

function run(root, env = {}) {
  const r = spawnSync('bash', [path.join(root, 'scripts/native-release-apk.sh')], {
    encoding: 'utf8',
    env: {
      PATH: process.env.PATH,
      HOME: path.join(root, 'home'),
      MOBISSH_TMPDIR: path.join(root, 'tmp'),
      MOBISSH_LOGDIR: path.join(root, 'logs'),
      NATIVE_DIST_HOST: path.join(root, 'dist'),
      MOBISSH_KEY_PROPERTIES: path.join(root, 'key.properties'),
      ...env,
    },
  });
  const read = (rel) => {
    const p = path.join(root, rel);
    return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null;
  };
  return {
    r,
    out: r.stdout + r.stderr,
    log: read('logs/native-release-apk.log') || '',
    args: read('flutter-args.txt'),
    captured: read('captured-inputs.json'),
    mode: (read('captured-mode.txt') || '').trim(),
    staged: fs.readdirSync(path.join(root, 'native')).filter((n) => /build-inputs/.test(n)),
    published: fs.existsSync(path.join(root, 'dist')),
  };
}

function feedbackEnv(root, key) {
  fs.mkdirSync(path.join(root, 'home/.mobissh'), { recursive: true });
  fs.writeFileSync(path.join(root, 'home/.mobissh/feedback.env'), `FEEDBACK_KEY=${key}\n`);
}

function assertNoLeak(res, key) {
  assert.ok(!res.out.includes(key), 'key leaked to stdout/stderr');
  assert.ok(!res.log.includes(key), 'key leaked to the log file');
  if (res.args) assert.ok(!res.args.includes(key), 'key leaked onto the flutter command line');
}

describe('#1277 feedback key via --dart-define-from-file', () => {
  it('the release script never puts the key in a --dart-define', () => {
    assert.doesNotMatch(fs.readFileSync(RELEASE, 'utf8'), /--dart-define=MOBISSH_FEEDBACK_KEY/);
  });

  it('feedback.env: stages a 0600 JSON in native/, passes it by relative path, deletes it', () => {
    const root = sandbox(RC);
    feedbackEnv(root, KEY);
    const res = run(root);
    assert.equal(res.r.status, 0, res.out);
    const arg = res.args.split('\n').find((a) => a.startsWith('--dart-define-from-file='));
    assert.ok(arg, res.args);
    assert.ok(!arg.includes('/'), `path must be relative to native/: ${arg}`);
    assert.deepEqual(JSON.parse(res.captured), { MOBISSH_FEEDBACK_KEY: KEY });
    assert.equal(res.mode, '600');
    assert.deepEqual(res.staged, [], 'staged inputs must be deleted after the build');
    assertNoLeak(res, KEY);
  });

  it('MOBISSH_BUILD_INPUTS: the key comes from the given JSON file', () => {
    const root = sandbox(RC);
    const inputs = path.join(root, 'inputs.json');
    fs.writeFileSync(inputs, JSON.stringify({ MOBISSH_FEEDBACK_KEY: `${KEY}-file` }));
    const res = run(root, { MOBISSH_BUILD_INPUTS: inputs });
    assert.equal(res.r.status, 0, res.out);
    assert.equal(JSON.parse(res.captured).MOBISSH_FEEDBACK_KEY, `${KEY}-file`);
    assert.equal(res.mode, '600');
    assert.deepEqual(res.staged, []);
    assertNoLeak(res, `${KEY}-file`);
  });

  it('a failed build still deletes the staged inputs', () => {
    const root = sandbox(RC);
    feedbackEnv(root, KEY);
    const res = run(root, { STUB_BUILD_FAIL: '1' });
    assert.equal(res.r.status, 2, res.out);
    assert.deepEqual(res.staged, []);
    assertNoLeak(res, KEY);
  });

  it('an unreadable inputs file is refused without echoing its contents', () => {
    const root = sandbox(RC);
    const inputs = path.join(root, 'inputs.json');
    fs.writeFileSync(inputs, `{"MOBISSH_FEEDBACK_KEY": "${KEY}",`);
    const res = run(root, { MOBISSH_BUILD_INPUTS: inputs });
    assert.equal(res.r.status, 2, res.out);
    assert.equal(res.args, null, 'no build may run');
    assert.deepEqual(res.staged, []);
    assertNoLeak(res, KEY);
  });

  it('an inputs file without MOBISSH_FEEDBACK_KEY is refused', () => {
    const root = sandbox(RC);
    const inputs = path.join(root, 'inputs.json');
    fs.writeFileSync(inputs, JSON.stringify({ OTHER: 'x' }));
    const res = run(root, { MOBISSH_BUILD_INPUTS: inputs });
    assert.equal(res.r.status, 2, res.out);
    assert.match(res.out, /MOBISSH_FEEDBACK_KEY/);
    assert.equal(res.args, null);
  });
});

describe('#1277 a missing feedback key fails closed', () => {
  it('refuses a release with no key, before any build', () => {
    const res = run(sandbox(RC));
    assert.equal(res.r.status, 2, res.out);
    assert.match(res.out, /MOBISSH_FEEDBACK_KEY|feedback key/i);
    assert.equal(res.args, null);
    assert.ok(!res.published, 'nothing may be published');
  });

  it('refuses a -dev build with no key unless opted out', () => {
    const res = run(sandbox(DEV));
    assert.equal(res.r.status, 2, res.out);
    assert.equal(res.args, null);
  });

  it('the opt-out does not apply to an rc or final build', () => {
    const res = run(sandbox(RC), { MOBISSH_ALLOW_NO_FEEDBACK_KEY: '1' });
    assert.equal(res.r.status, 2, res.out);
    assert.match(res.out, /-dev/);
    assert.equal(res.args, null);
  });

  it('MOBISSH_ALLOW_NO_FEEDBACK_KEY=1 builds a -dev build without inputs', () => {
    const res = run(sandbox(DEV), { MOBISSH_ALLOW_NO_FEEDBACK_KEY: '1' });
    assert.equal(res.r.status, 0, res.out);
    assert.doesNotMatch(res.args, /--dart-define-from-file/);
    assert.match(res.out, /WITHOUT a feedback key/);
  });
});
