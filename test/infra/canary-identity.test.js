/**
 * test/infra/canary-identity.test.js
 *
 * #1277 (homelab#44 joint canary): `-Pmobissh.canary=true` (flutter:
 * --android-project-arg=mobissh.canary=true) builds com.flavordrake.mobissh.canary
 * with a distinct label, so a canary can never install over the real app, and it
 * never takes the production signing config (the canary is signed with a
 * disposable key). Default builds keep their applicationId, label and output
 * names: a property, not a product flavor (a flavor renames every APK path).
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const strip = (src) => src.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
const GRADLE = strip(fs.readFileSync(path.join(REPO_ROOT, 'native/android/app/build.gradle.kts'), 'utf8'));
const MANIFEST = fs.readFileSync(path.join(REPO_ROOT, 'native/android/app/src/main/AndroidManifest.xml'), 'utf8');

describe('#1277 canary identity', () => {
  it('is selected by the mobissh.canary Gradle property', () => {
    assert.match(GRADLE, /val isCanary = providers\.gradleProperty\("mobissh\.canary"\)/);
  });

  it('canary gets the .canary applicationId; the default is unchanged', () => {
    assert.match(GRADLE, /applicationId = "com\.flavordrake\.mobissh"/);
    assert.match(GRADLE, /if \(isCanary\) \{[^}]*applicationIdSuffix = "\.canary"/);
  });

  it('the app label is a placeholder: "mobissh" by default, distinct for the canary', () => {
    assert.match(MANIFEST, /android:label="\$\{appLabel\}"/);
    assert.match(GRADLE, /manifestPlaceholders\["appLabel"\] = if \(isCanary\) "MobiSSH Canary" else "mobissh"/);
  });

  it('a canary never uses the production signing config', () => {
    assert.match(GRADLE, /signingConfig = if \(keystoreProperties\.isNotEmpty\(\) && !isCanary\)/);
  });

  it('adds no product flavors (default APK names stay app-<abi>-release.apk)', () => {
    assert.doesNotMatch(GRADLE, /productFlavors/);
  });
});
