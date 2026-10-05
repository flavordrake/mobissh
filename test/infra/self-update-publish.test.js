/**
 * test/infra/self-update-publish.test.js
 *
 * Self-update publish side (#1215, spec docs/self-update.md R1-R4, tests A1-A2).
 *
 * A1: scripts/gen-android-latest-json.sh writes the pinned manifest contract
 *     (shape, sha256 of the published stamped APK, https same-host url, integer
 *     build), refuses to name an APK that is not in place, and replaces the
 *     manifest atomically. scripts/native-release-apk.sh is run in a sandbox repo
 *     with a stub flutter-cmd.sh: a missing keystore exits 2 before any build
 *     (R4); a present one passes MOBISSH_BUILD=<B> (R2) and publishes the
 *     manifest beside the APK (R1).
 * A2: server/index.js serves /android-latest.json from native-dist as no-store
 *     JSON; any other JSON name is still 404 (R3).
 */

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync, execFileSync } = require('node:child_process');
const crypto = require('node:crypto');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const GEN = path.join(REPO_ROOT, 'scripts/gen-android-latest-json.sh');
const RELEASE = path.join(REPO_ROOT, 'scripts/native-release-apk.sh');
const HOST = 'https://mobissh.tailbe5094.ts.net';
const VERSION = '0.1.12-rc.4+191';
// #1277: the release script refuses unless the stub reports the pinned SDK.
const FLUTTER_PIN = fs.readFileSync(path.join(REPO_ROOT, 'native/.flutter-version'), 'utf8').trim();
const VERSION_STUB = `if [[ "$1" == --version ]]; then echo '"frameworkVersion": "${FLUTTER_PIN}"'; exit 0; fi`;

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function tmpdir(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `su1215-${tag}-`));
}

function runGen(args) {
  return spawnSync('bash', [GEN, ...args], { encoding: 'utf8' });
}

// #1258: "What's new" is the TOP `## ` section of native-release-notes.md.
const TOP_SECTION = [
  '## v0.1.13+199 (2026-10-02) — fewer taps to update',
  '- **Updates are ready before you tap.** On Wi-Fi the next build downloads first. (#1258)',
  '- Second bullet.',
].join('\n');
const RELEASE_NOTES_FIXTURE = [
  '# MobiSSH native — release notes',
  '',
  'Curated preamble, not part of any section.',
  '',
  TOP_SECTION,
  '',
  '## v0.1.12 (2026-09-19) — older',
  '- Older bullet.',
  '',
].join('\n');

describe('#1258 release-notes-top.sh', () => {
  const TOP = path.join(REPO_ROOT, 'scripts/release-notes-top.sh');

  it('prints only the top section, without trailing blank lines', () => {
    const f = path.join(tmpdir('top'), 'notes.md');
    fs.writeFileSync(f, RELEASE_NOTES_FIXTURE);
    const r = spawnSync('bash', [TOP, f], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, `${TOP_SECTION}\n`);
  });

  it('prints nothing (exit 0) for a file with no section or no file', () => {
    const f = path.join(tmpdir('top-none'), 'notes.md');
    fs.writeFileSync(f, '# title\n\npreamble\n');
    const r = spawnSync('bash', [TOP, f], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, '');
    const missing = spawnSync('bash', [TOP, f + '.nope'], { encoding: 'utf8' });
    assert.equal(missing.status, 0, missing.stderr);
    assert.equal(missing.stdout, '');
  });

  it('the repo release notes have a top section to publish', () => {
    const r = spawnSync('bash', [TOP, path.join(REPO_ROOT, 'native-release-notes.md')],
      { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /^## /);
    assert.equal((r.stdout.match(/^## /gm) || []).length, 1);
  });
});

describe('A1 gen-android-latest-json.sh (R1)', () => {
  it('writes the pinned contract for the published stamped APK', () => {
    const dist = tmpdir('gen');
    const stamped = `mobissh-native-${VERSION}-20260927T172906+0000.apk`;
    fs.writeFileSync(path.join(dist, stamped), 'fake apk bytes 1215');
    const r = runGen([dist, stamped, VERSION, HOST, 'ship(native): notes line\nsecond line']);
    assert.equal(r.status, 0, r.stderr);

    const m = JSON.parse(fs.readFileSync(path.join(dist, 'android-latest.json'), 'utf8'));
    assert.deepEqual(Object.keys(m).sort(),
      ['abi', 'build', 'builtAt', 'notes', 'sha256', 'url', 'version']);
    assert.equal(m.version, VERSION);
    assert.equal(m.build, 191);
    assert.equal(typeof m.build, 'number');
    assert.equal(m.abi, 'arm64-v8a');
    assert.equal(m.url, `${HOST}/${stamped}`);
    assert.match(m.sha256, /^[0-9a-f]{64}$/);
    assert.equal(m.sha256, sha256(path.join(dist, stamped)));
    assert.match(m.builtAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    assert.equal(m.notes, 'ship(native): notes line');

    const u = new URL(m.url);
    assert.equal(u.protocol, 'https:');
    assert.equal(u.host, new URL(HOST).host);
    // atomic: nothing but the APK and the manifest is left in the dist dir
    assert.deepEqual(fs.readdirSync(dist).sort(), ['android-latest.json', stamped].sort());
  });

  it('notes may be empty', () => {
    const dist = tmpdir('gen-empty');
    const stamped = `mobissh-native-${VERSION}-x.apk`;
    fs.writeFileSync(path.join(dist, stamped), 'x');
    const r = runGen([dist, stamped, VERSION, HOST]);
    assert.equal(r.status, 0, r.stderr);
    const m = JSON.parse(fs.readFileSync(path.join(dist, 'android-latest.json'), 'utf8'));
    assert.equal(m.notes, '');
  });

  it('refuses (and keeps the old manifest) when the named APK is not in place', () => {
    const dist = tmpdir('gen-missing');
    fs.writeFileSync(path.join(dist, 'android-latest.json'), '{"old":true}');
    const r = runGen([dist, `mobissh-native-${VERSION}-missing.apk`, VERSION, HOST]);
    assert.notEqual(r.status, 0);
    assert.equal(fs.readFileSync(path.join(dist, 'android-latest.json'), 'utf8'), '{"old":true}');
    assert.deepEqual(fs.readdirSync(dist), ['android-latest.json']);
  });

  it('refuses a non-https serve host', () => {
    const dist = tmpdir('gen-http');
    fs.writeFileSync(path.join(dist, 'a.apk'), 'x');
    const r = runGen([dist, 'a.apk', VERSION, 'http://mobissh.tailbe5094.ts.net']);
    assert.notEqual(r.status, 0);
    assert.ok(!fs.existsSync(path.join(dist, 'android-latest.json')));
  });

  it('refuses a version without an integer build ordinal', () => {
    const dist = tmpdir('gen-ver');
    fs.writeFileSync(path.join(dist, 'a.apk'), 'x');
    const r = runGen([dist, 'a.apk', '0.1.12-rc.4', HOST]);
    assert.notEqual(r.status, 0);
    assert.ok(!fs.existsSync(path.join(dist, 'android-latest.json')));
  });

  it('#1258: NOTES_FILE puts the top release-notes section into notes', () => {
    const dist = tmpdir('gen-notesfile');
    const stamped = `mobissh-native-${VERSION}-n.apk`;
    fs.writeFileSync(path.join(dist, stamped), 'x');
    const notesFile = path.join(tmpdir('notes'), 'native-release-notes.md');
    fs.writeFileSync(notesFile, RELEASE_NOTES_FIXTURE);
    const r = runGen([dist, stamped, VERSION, HOST, 'ship(native): subject', notesFile]);
    assert.equal(r.status, 0, r.stderr);
    const m = JSON.parse(fs.readFileSync(path.join(dist, 'android-latest.json'), 'utf8'));
    assert.equal(m.notes, TOP_SECTION);
  });

  it('#1258: a notes file with no section falls back to the NOTES line', () => {
    const dist = tmpdir('gen-notesfile-empty');
    const stamped = `mobissh-native-${VERSION}-e.apk`;
    fs.writeFileSync(path.join(dist, stamped), 'x');
    const notesFile = path.join(tmpdir('notes-empty'), 'native-release-notes.md');
    fs.writeFileSync(notesFile, '# MobiSSH native — release notes\n\nPreamble only.\n');
    const r = runGen([dist, stamped, VERSION, HOST, 'ship(native): subject\nmore', notesFile]);
    assert.equal(r.status, 0, r.stderr);
    const m = JSON.parse(fs.readFileSync(path.join(dist, 'android-latest.json'), 'utf8'));
    assert.equal(m.notes, 'ship(native): subject');
  });

  it('replaces the manifest by rename from a temp in the same dir', () => {
    const src = fs.readFileSync(GEN, 'utf8');
    assert.match(src, /mktemp[^\n]*\$\{?DIST/);
    assert.match(src, /mv -f/);
  });
});

// Sandbox copy of the repo layout native-release-apk.sh touches, with every
// external step stubbed so the test never runs a real build or network call.
function makeSandbox() {
  const root = tmpdir('rel');
  const w = (rel, body, mode) => {
    const p = path.join(root, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, body);
    if (mode) fs.chmodSync(p, mode);
  };
  w('scripts/native-release-apk.sh', fs.readFileSync(RELEASE), 0o755);
  if (fs.existsSync(GEN)) w('scripts/gen-android-latest-json.sh', fs.readFileSync(GEN), 0o755);
  const top = path.join(REPO_ROOT, 'scripts/release-notes-top.sh');
  if (fs.existsSync(top)) w('scripts/release-notes-top.sh', fs.readFileSync(top), 0o755);
  w('scripts/flutter-cmd.sh', [
    '#!/usr/bin/env bash',
    VERSION_STUB,
    'ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
    'printf "%s\\n" "$@" > "$ROOT/flutter-args.txt"',
    'OUT="$ROOT/native/build/app/outputs/flutter-apk"',
    'mkdir -p "$OUT"',
    'printf "arm64 apk 1215" > "$OUT/app-arm64-v8a-release.apk"',
    '',
  ].join('\n'), 0o755);
  w('scripts/gen-apk-install-page.sh',
    '#!/usr/bin/env bash\nROOT="$(cd "$(dirname "$0")/.." && pwd)"\necho page > "$ROOT/public/native.html"\n', 0o755);
  w('scripts/notify-build.sh', '#!/usr/bin/env bash\nexit 0\n', 0o755);
  w('native/pubspec.yaml', `name: mobissh\nversion: ${VERSION}\n`);
  w('native/.flutter-version', `${FLUTTER_PIN}\n`);
  w('public/native-time.js', '//');
  w('public/native-feedback.js', '//');
  w('home/.mobissh/feedback.env', 'FEEDBACK_KEY=test-key\n'); // #1277: a keyless release is refused
  const git = (...a) => execFileSync('git', ['-C', root, ...a], { stdio: 'ignore' });
  git('init', '-q');
  git('add', '-A');
  git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'ship(native): sandbox notes');
  return root;
}

function runRelease(root, keyProps) {
  return spawnSync('bash', [path.join(root, 'scripts/native-release-apk.sh')], {
    encoding: 'utf8',
    env: {
      PATH: process.env.PATH,
      HOME: path.join(root, 'home'),
      MOBISSH_TMPDIR: path.join(root, 'tmp'),
      MOBISSH_LOGDIR: path.join(root, 'logs'),
      NATIVE_DIST_HOST: path.join(root, 'dist'),
      MOBISSH_KEY_PROPERTIES: keyProps,
    },
  });
}

describe('A1 native-release-apk.sh (R1, R2, R4)', () => {
  it('R4: missing keystore exits 2 before any build', () => {
    const root = makeSandbox();
    const r = runRelease(root, path.join(root, 'no-such-key.properties'));
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.ok(!fs.existsSync(path.join(root, 'flutter-args.txt')), 'flutter-cmd.sh must not run');
    assert.match(r.stdout + r.stderr, /key\.properties|keystore/i);
  });

  it('R2+R1: passes MOBISSH_BUILD=<B> and publishes the manifest beside the APK', () => {
    const root = makeSandbox();
    const key = path.join(root, 'key.properties');
    fs.writeFileSync(key, 'storeFile=x\n');
    const r = runRelease(root, key);
    assert.equal(r.status, 0, r.stdout + r.stderr);

    const args = fs.readFileSync(path.join(root, 'flutter-args.txt'), 'utf8').split('\n');
    assert.ok(args.includes('--dart-define=MOBISSH_BUILD=191'), args.join(' '));

    const dist = path.join(root, 'dist');
    const m = JSON.parse(fs.readFileSync(path.join(dist, 'android-latest.json'), 'utf8'));
    assert.equal(m.build, 191);
    const apk = path.join(dist, path.basename(new URL(m.url).pathname));
    assert.ok(fs.existsSync(apk), `manifest names ${apk}, which is not published`);
    assert.match(path.basename(apk), /^mobissh-native-0\.1\.12-rc\.4\+191-.*\.apk$/);
    assert.equal(m.sha256, sha256(apk));
    assert.equal(m.notes, 'ship(native): sandbox notes');
  });

  it('#1258: publishes the top section of native-release-notes.md as notes', () => {
    const root = makeSandbox();
    fs.writeFileSync(path.join(root, 'native-release-notes.md'), RELEASE_NOTES_FIXTURE);
    const key = path.join(root, 'key.properties');
    fs.writeFileSync(key, 'storeFile=x\n');
    const r = runRelease(root, key);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const m = JSON.parse(fs.readFileSync(path.join(root, 'dist', 'android-latest.json'), 'utf8'));
    assert.equal(m.notes, TOP_SECTION);
  });
});

// #1271 (0.1.13 security review, finding 2): build outputs can come back from a
// remote builder with symlinks intact. `[[ -f ]]` and `cp` follow them, so a
// symlinked "APK" would publish whatever it points at (key.properties, the
// keystore, feedback.env) on the tailnet. The release script must refuse.
describe('#1271 native-release-apk.sh refuses symlinked build outputs', () => {
  function plantStub(root, apkName) {
    fs.writeFileSync(path.join(root, 'scripts/flutter-cmd.sh'), [
      '#!/usr/bin/env bash',
      VERSION_STUB,
      'ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
      'OUT="$ROOT/native/build/app/outputs/flutter-apk"',
      'mkdir -p "$OUT"',
      'printf "arm64 apk 1271" > "$OUT/app-arm64-v8a-release.apk"',
      `rm -f "$OUT/${apkName}"`,
      `ln -s "$ROOT/secret.properties" "$OUT/${apkName}"`,
      '',
    ].join('\n'));
    fs.chmodSync(path.join(root, 'scripts/flutter-cmd.sh'), 0o755);
  }

  function published(root) {
    const out = [];
    for (const dir of ['public', 'dist']) {
      const d = path.join(root, dir);
      if (!fs.existsSync(d)) continue;
      for (const n of fs.readdirSync(d)) {
        const p = path.join(d, n);
        if (fs.statSync(p).isFile()) out.push(fs.readFileSync(p, 'utf8'));
      }
    }
    return out;
  }

  for (const apk of [
    'app-arm64-v8a-release.apk',
    'app-armeabi-v7a-release.apk',
    'app-x86_64-release.apk',
  ]) {
    it(`a symlinked ${apk} is refused and its target is never published`, () => {
      const root = makeSandbox();
      fs.writeFileSync(path.join(root, 'secret.properties'), 'storePassword=SECRET-1271\n');
      plantStub(root, apk);
      const key = path.join(root, 'key.properties');
      fs.writeFileSync(key, 'storeFile=x\n');
      const r = runRelease(root, key);
      assert.equal(r.status, 2, r.stdout + r.stderr);
      assert.match(r.stdout + r.stderr, /symlink|regular file/i);
      for (const body of published(root)) {
        assert.ok(!body.includes('SECRET-1271'), 'the symlink target was published');
      }
      assert.ok(!fs.existsSync(path.join(root, 'dist', 'android-latest.json')),
        'no manifest may name a refused build');
    });
  }
});

describe('A2 server serves android-latest.json (R3)', () => {
  let port = 0;
  let server;
  const dist = tmpdir('srv');
  const body = '{"build":191}';

  before(async () => {
    fs.writeFileSync(path.join(dist, 'android-latest.json'), body);
    fs.writeFileSync(path.join(dist, 'other-latest.json'), '{"leak":true}');
    process.env.NATIVE_DIST_DIR = dist;
    ({ server } = require(path.join(REPO_ROOT, 'server/index.js')));
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    port = server.address().port;
  });

  after(() => new Promise((resolve) => server.close(resolve)));

  function get(p) {
    return new Promise((resolve, reject) => {
      http.get({ host: '127.0.0.1', port, path: p }, (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, data }));
      }).on('error', reject);
    });
  }

  it('/android-latest.json is served no-store as JSON', async () => {
    const r = await get('/android-latest.json');
    assert.equal(r.status, 200);
    assert.equal(r.data, body);
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.match(r.headers['content-type'], /^application\/json/);
  });

  it('other JSON in native-dist is still 404', async () => {
    const r = await get('/other-latest.json');
    assert.equal(r.status, 404);
  });
});
