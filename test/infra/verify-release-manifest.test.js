/**
 * test/infra/verify-release-manifest.test.js
 *
 * #1277 (client side of homelab#44): scripts/verify-release-manifest.py is the
 * gate between the isolated builder+signer and anything mobissh publishes.
 * DRAFT: the manifest shape below is ours, pending homelab#44's frozen fixtures.
 *
 * Every refusal must exit non-zero and never print VERIFIED. Fixtures are
 * generated per run: a node Ed25519 provenance key and a throwaway keytool test
 * cert; the production key is never touched. Cases that need a real APK
 * (aapt2 + apksigner + keytool) skip WITH a reason where the SDK is absent.
 */

const { describe, it, before } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync, execFileSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const VERIFY = path.join(REPO_ROOT, 'scripts/verify-release-manifest.py');
const SHA = 'a'.repeat(40);
const JOB = 'job-1277-test';
const PROJECT = 'flavordrake/mobissh';
const APKS = ['app-armeabi-v7a-release.apk', 'app-arm64-v8a-release.apk', 'app-x86_64-release.apk'];

// The SDK lives at /opt/android-sdk on fd-dev and at $ANDROID_HOME on a CI runner.
function sdkTool(rel) {
  const roots = ['/opt/android-sdk', process.env.ANDROID_HOME, process.env.ANDROID_SDK_ROOT].filter(Boolean);
  for (const root of roots) {
    const bt = path.join(root, 'build-tools');
    if (!fs.existsSync(bt)) continue;
    const versions = fs.readdirSync(bt).sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).reverse();
    for (const v of versions) {
      const p = path.join(bt, v, rel);
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}
function androidJar() {
  for (const root of ['/opt/android-sdk', process.env.ANDROID_HOME, process.env.ANDROID_SDK_ROOT].filter(Boolean)) {
    const p = path.join(root, 'platforms');
    if (!fs.existsSync(p)) continue;
    const jars = fs.readdirSync(p).map((d) => path.join(p, d, 'android.jar')).filter((j) => fs.existsSync(j));
    if (jars.length) return jars.sort().pop();
  }
  return null;
}
const APKSIGNER = sdkTool('apksigner');
const AAPT2 = sdkTool('aapt2');
const JAR = androidJar();
const HAS_KEYTOOL = spawnSync('keytool', ['-help'], { stdio: 'ignore' }).status === 0;
const SDK_SKIP = APKSIGNER && AAPT2 && JAR && HAS_KEYTOOL
  ? false
  : 'needs Android build-tools (apksigner, aapt2), a platform android.jar and keytool';

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

let FIX; // { dir, unsigned, signed: {name: path}, certSha }

function buildApkFixtures() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vrm1277-fix-'));
  const fix = { dir, signed: {}, certSha: null, unsigned: null };
  if (SDK_SKIP) {
    for (const n of APKS) {
      fix.signed[n] = path.join(dir, n);
      fs.writeFileSync(fix.signed[n], `not a real apk ${n}`);
    }
    return fix;
  }
  const manifest = path.join(dir, 'AndroidManifest.xml');
  fs.writeFileSync(manifest, '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
    + 'package="com.example.fixture1277"><uses-sdk android:minSdkVersion="24" '
    + 'android:targetSdkVersion="36"/><application/></manifest>');
  fix.unsigned = path.join(dir, 'unsigned.apk');
  execFileSync(AAPT2, ['link', '-o', fix.unsigned, '--manifest', manifest, '-I', JAR]);
  const ks = path.join(dir, 'test.jks');
  // Throwaway TEST cert; never the production key.
  execFileSync('keytool', ['-genkeypair', '-keystore', ks, '-storepass', 'testpass', '-keypass', 'testpass',
    '-alias', 'test', '-keyalg', 'EC', '-groupname', 'secp256r1', '-dname', 'CN=MobiSSH Test Fixture',
    '-validity', '2', '-noprompt'], { stdio: 'ignore' });
  for (const n of APKS) {
    fix.signed[n] = path.join(dir, n);
    execFileSync(APKSIGNER, ['sign', '--ks', ks, '--ks-pass', 'pass:testpass', '--ks-key-alias', 'test',
      '--out', fix.signed[n], fix.unsigned]);
  }
  const out = execFileSync(APKSIGNER, ['verify', '--print-certs', fix.signed[APKS[0]]], { encoding: 'utf8' });
  fix.certSha = /certificate SHA-256 digest: ([0-9a-f]{64})/.exec(out)[1];
  return fix;
}

// A complete, valid release: artifacts dir + signed manifest + provenance key.
function makeRelease(over = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vrm1277-'));
  const art = path.join(root, 'artifacts');
  fs.mkdirSync(art);
  const artifacts = {};
  for (const n of APKS) {
    fs.copyFileSync(FIX.signed[n], path.join(art, n));
    artifacts[n] = sha256(fs.readFileSync(path.join(art, n)));
  }
  const body = {
    schema: 'mobissh-release-manifest/draft-1',
    project: PROJECT,
    source_sha: SHA,
    job_id: JOB,
    issued_at: new Date().toISOString(),
    artifacts,
    ...over,
  };
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const rel = {
    root,
    art,
    manifest: path.join(root, 'manifest.json'),
    sig: path.join(root, 'manifest.json.sig'),
    pub: path.join(root, 'provenance.pub.pem'),
    privateKey,
  };
  fs.writeFileSync(rel.pub, publicKey.export({ type: 'spki', format: 'pem' }));
  rel.write = (text) => {
    fs.writeFileSync(rel.manifest, text);
    fs.writeFileSync(rel.sig, crypto.sign(null, Buffer.from(text), privateKey));
  };
  rel.write(JSON.stringify(body, null, 2));
  return rel;
}

function verify(rel, extra = {}) {
  const a = {
    '--manifest': rel.manifest,
    '--signature': rel.sig,
    '--pubkey': rel.pub,
    '--expected-sha': SHA,
    '--expected-project': PROJECT,
    '--expected-job': JOB,
    '--artifacts': rel.art,
    '--apksigner': APKSIGNER || '/nonexistent/apksigner',
    '--expected-cert-sha256': FIX.certSha || '0'.repeat(64),
    ...extra,
  };
  const args = [VERIFY];
  for (const [k, v] of Object.entries(a)) if (v !== null) args.push(k, v);
  return spawnSync('python3', args, { encoding: 'utf8' });
}

function refused(r, re) {
  const out = r.stdout + r.stderr;
  assert.notEqual(r.status, 0, `expected refusal, got exit 0:\n${out}`);
  assert.doesNotMatch(r.stdout, /VERIFIED/);
  if (re) assert.match(out, re);
}

before(() => { FIX = buildApkFixtures(); });

describe('#1277 verify-release-manifest.py (DRAFT pending homelab#44)', () => {
  it('is marked DRAFT and pins the production cert by default', () => {
    const src = fs.readFileSync(VERIFY, 'utf8');
    assert.match(src, /DRAFT/);
    assert.match(src, /homelab#44/);
    assert.match(src, /f01111d967cefce5de58cbe88264539e064f2e9b8c70da133b490def28f8d2eb/);
  });

  it('is not wired into the ship path yet', () => {
    for (const f of ['scripts/ship-native.sh', 'scripts/native-release-apk.sh']) {
      assert.doesNotMatch(fs.readFileSync(path.join(REPO_ROOT, f), 'utf8'), /verify-release-manifest/);
    }
  });

  it('accepts a complete, signed, matching release', { skip: SDK_SKIP }, () => {
    const r = verify(makeRelease());
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /VERIFIED/);
  });

  describe('source / job identity', () => {
    it('refuses a source SHA mismatch', () => {
      refused(verify(makeRelease({ source_sha: 'b'.repeat(40) })), /source_sha/);
    });
    it('refuses an abbreviated expected SHA', () => {
      refused(verify(makeRelease({ source_sha: 'aaaaaaa' }), { '--expected-sha': 'aaaaaaa' }), /sha/i);
    });
    it('refuses a project mismatch', () => {
      refused(verify(makeRelease({ project: 'flavordrake/other' })), /project/);
    });
    it('refuses a job id mismatch', () => {
      refused(verify(makeRelease({ job_id: 'job-other' })), /job/);
    });
    it('refuses a stale job', () => {
      const old = new Date(Date.now() - 3 * 86400 * 1000).toISOString();
      refused(verify(makeRelease({ issued_at: old })), /stale|issued_at/);
    });
    it('refuses a job issued in the future', () => {
      const future = new Date(Date.now() + 3600 * 1000).toISOString();
      refused(verify(makeRelease({ issued_at: future })), /issued_at/);
    });
    it('refuses a missing issued_at', () => {
      refused(verify(makeRelease({ issued_at: undefined })), /issued_at/);
    });
  });

  describe('signature', () => {
    it('refuses a missing signature file', () => {
      const rel = makeRelease();
      fs.unlinkSync(rel.sig);
      refused(verify(rel), /signature/);
    });
    it('refuses an empty signature', () => {
      const rel = makeRelease();
      fs.writeFileSync(rel.sig, '');
      refused(verify(rel), /signature/);
    });
    it('refuses a manifest edited after signing', () => {
      const rel = makeRelease();
      const text = fs.readFileSync(rel.manifest, 'utf8').replace(JOB, `${JOB} `);
      fs.writeFileSync(rel.manifest, text);
      refused(verify(rel), /signature/);
    });
    it('refuses a signature by a different key', () => {
      const rel = makeRelease();
      const other = crypto.generateKeyPairSync('ed25519').publicKey;
      fs.writeFileSync(rel.pub, other.export({ type: 'spki', format: 'pem' }));
      refused(verify(rel), /signature/);
    });
    it('refuses an unknown signature scheme', () => {
      refused(verify(makeRelease(), { '--sig-scheme': 'none' }), /scheme/);
    });
    it('refuses a manifest with a duplicated key', () => {
      const rel = makeRelease();
      const text = fs.readFileSync(rel.manifest, 'utf8').replace(/\n}$/, `,\n  "job_id": "${JOB}"\n}`);
      rel.write(text);
      refused(verify(rel), /duplicate/);
    });
  });

  describe('artifact set', () => {
    it('refuses a missing artifact', () => {
      const rel = makeRelease();
      fs.unlinkSync(path.join(rel.art, APKS[2]));
      refused(verify(rel), /missing/);
    });
    it('refuses an extra file', () => {
      const rel = makeRelease();
      fs.writeFileSync(path.join(rel.art, 'notes.txt'), 'x');
      refused(verify(rel), /extra|unexpected/);
    });
    it('refuses an extra directory', () => {
      const rel = makeRelease();
      fs.mkdirSync(path.join(rel.art, 'sub'));
      refused(verify(rel), /extra|unexpected|regular/);
    });
    it('refuses a symlinked artifact even when its target hashes right', () => {
      const rel = makeRelease();
      const target = path.join(rel.root, 'outside.apk');
      fs.renameSync(path.join(rel.art, APKS[1]), target);
      fs.symlinkSync(target, path.join(rel.art, APKS[1]));
      refused(verify(rel), /symlink|regular/);
    });
    it('refuses a non-regular artifact (FIFO)', () => {
      const rel = makeRelease();
      fs.unlinkSync(path.join(rel.art, APKS[0]));
      execFileSync('mkfifo', [path.join(rel.art, APKS[0])]);
      refused(verify(rel), /regular/);
    });
    it('refuses a manifest that omits an expected APK', () => {
      const rel = makeRelease();
      const m = JSON.parse(fs.readFileSync(rel.manifest, 'utf8'));
      delete m.artifacts[APKS[0]];
      fs.unlinkSync(path.join(rel.art, APKS[0]));
      rel.write(JSON.stringify(m));
      refused(verify(rel), /artifact/);
    });
    it('refuses a manifest naming a path outside the directory', () => {
      const rel = makeRelease();
      const m = JSON.parse(fs.readFileSync(rel.manifest, 'utf8'));
      m.artifacts['../manifest.json'] = sha256(fs.readFileSync(rel.manifest));
      rel.write(JSON.stringify(m));
      refused(verify(rel), /artifact/);
    });
    it('refuses an artifact hash mismatch', () => {
      const rel = makeRelease();
      fs.appendFileSync(path.join(rel.art, APKS[1]), 'tampered');
      refused(verify(rel), /hash|sha256/);
    });
  });

  describe('APK certificate', () => {
    it('refuses an APK signed by a cert that is not the production pin', { skip: SDK_SKIP }, () => {
      refused(verify(makeRelease(), { '--expected-cert-sha256': null }), /cert/);
    });
    it('refuses an unsigned APK whose hash matches the manifest', { skip: SDK_SKIP }, () => {
      const rel = makeRelease();
      const m = JSON.parse(fs.readFileSync(rel.manifest, 'utf8'));
      fs.copyFileSync(FIX.unsigned, path.join(rel.art, APKS[1]));
      m.artifacts[APKS[1]] = sha256(fs.readFileSync(FIX.unsigned));
      rel.write(JSON.stringify(m));
      refused(verify(rel), /cert|apksigner/);
    });
    it('refuses when apksigner is unavailable', { skip: SDK_SKIP }, () => {
      refused(verify(makeRelease(), { '--apksigner': '/nonexistent/apksigner' }), /apksigner/);
    });
  });
});
