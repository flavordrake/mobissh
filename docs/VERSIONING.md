# Native versioning and release-candidate workflow

The single source of truth is the `version:` line in `native/pubspec.yaml`, shaped as SemVer 2.0.0:

```
x.y.z[-STAGE]+B      e.g. 0.1.13-dev+170, 0.1.13-rc.1+174, 0.1.13+176
```

SemVer mandates this ordering: pre-release stage BEFORE build metadata, rc numbers with a dot (`rc.1`, not `rc1`). Precedence works out exactly as the lifecycle needs: `x.y.z-dev < x.y.z-rc.1 < x.y.z-rc.2 < x.y.z`.

## The two invariants

1. **`+B` is a single global build ordinal that never resets.** It IS the Android `versionCode` (`build.gradle.kts` takes it from the pubspec split at the last `+`) and the macOS `CFBundleVersion`. Both platforms require it to strictly increase forever across all installs, so a per-version reset is impossible on the channels users install from. B answers "which exact bits am I holding" — on the device (Settings/bug reports), in the APK filename, and in `data-version` on the install page. `scripts/ship-native.sh` auto-increments it and refuses to ship a B that does not advance (`scripts/lib/next-build-version.sh`, gated by `scripts/test-next-build-version.sh`).
2. **Stage only moves forward within a version:** `-dev` → `-rc.1` → `-rc.2` → … → (none). Never backwards, never skipping into a different `x.y.z` without starting at `-dev` or `-rc.1`.

`x.y.z-STAGE` answers "where in the release lifecycle is this"; `+B` answers "which build". Don't make either carry the other's job.

## Lifecycle

1. **Dev.** Immediately after a release ships, bump the pubspec to `x.y.(z+1)-dev+B` (B just keeps counting). All work-in-progress ships as `-dev` builds — owner-testable, no release ceremony.
2. **RC entry.** When the release scope is believed complete and entry gates are green, set `x.y.z-rc.1+B`, ship, tag `native-vx.y.z-rc.1`, cut a GH **prerelease**.
3. **Iterate within an rc.** Bugs found during rc.N acceptance testing are fixed and shipped as new builds still labeled `rc.N` — each carries a unique +B, so `rc.1+174` vs `rc.1+175` identifies the exact bits under test.
4. **RC promotion.** When the fixed candidate passes the RC entry gates again, bump to `rc.(N+1)`, tag `native-vx.y.z-rc.(N+1)`. An rc bump means "entry gates green on this lineage"; a build bump within an rc means "same candidate lineage, revised bits".
5. **Final.** When an rc survives acceptance with no further changes, ship ONE promotion build as `x.y.z+B` and tag `native-vx.y.z` (full GH release). The version string is baked into the binary at build time, so literally re-tagging the rc bits would ship an app that self-identifies as an rc — the promotion build is byte-different only in its version string. Then return to step 1.

## Worked example

```
0.1.13-dev+168 … 0.1.13-dev+173   development builds
0.1.13-rc.1+174                    RC entry, tag native-v0.1.13-rc.1, prerelease
0.1.13-rc.1+175                    fix during acceptance (same candidate lineage)
0.1.13-rc.2+176                    entry gates green again → promoted candidate, tag rc.2
0.1.13+177                         final promotion build, tag native-v0.1.13, release
0.1.14-dev+178                     next cycle begins
```

## Known ceiling (tracked)

`flutter build apk --split-per-abi` derives per-ABI versionCodes as `abi*1000 + B`, and the in-app build display reverses that with `% 1000`. Both break when B reaches 1000. Tracked as a chore issue; fix options are recorded there (drop split-per-abi, or widen the multiplier and fix both `% 1000` sites + their test).
