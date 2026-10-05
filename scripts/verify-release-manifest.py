#!/usr/bin/env python3
"""scripts/verify-release-manifest.py: refuse any release the builder+signer can't prove.

DRAFT (#1277), pending homelab#44's frozen API and manifest fixtures. The manifest
shape, the signature scheme name and the CLI below are mobissh's proposal; adapt
them when the fixtures land. NOT wired into ship-native.sh yet.

Checks, in order (the first failure exits 1; nothing is ever written or published):
  1. a detached signature over the raw manifest bytes verifies with the provenance key
  2. the manifest is a JSON object with no duplicate keys
  3. project, full 40-hex source_sha, job_id and the integer build_number
     (MOBISSH_BUILD) equal the expected values; issued_at is recent (not stale,
     not in the future)
  4. the manifest names exactly the three --split-per-abi release APKs
  5. the artifact directory holds exactly those names, each a regular file (lstat:
     no symlinks, FIFOs, devices or directories), each matching its sha256
  6. every APK verifies with apksigner and every signer cert is the pinned cert

Draft manifest (UTF-8 JSON):
  {"schema": "mobissh-release-manifest/draft-1", "project": "flavordrake/mobissh",
   "source_sha": "<40 hex>", "job_id": "<id>", "build_number": <int B>,
   "issued_at": "<ISO-8601 UTC>",
   "artifacts": {"app-arm64-v8a-release.apk": "<sha256 hex>", ...}}

Exit: 0 verified, 1 refused, 2 usage.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import stat
import subprocess
import sys

# Production signing cert (CN=MobiSSH, O=flavordrake, C=US, alias mobissh).
PINNED_CERT_SHA256 = "f01111d967cefce5de58cbe88264539e064f2e9b8c70da133b490def28f8d2eb"
DEFAULT_APKSIGNER = "/opt/android-sdk/build-tools/36.0.0/apksigner"
EXPECTED_APKS = frozenset({
    "app-armeabi-v7a-release.apk",
    "app-arm64-v8a-release.apk",
    "app-x86_64-release.apk",
})
FUTURE_SKEW_SECONDS = 300


class Refused(Exception):
    pass


def verify_ed25519_openssl(manifest_path, signature_path, pubkey_path):
    # Python's stdlib has no Ed25519; the openssl CLI (3.x, already on every host
    # that builds) does it without adding a pip dependency like `cryptography`.
    r = subprocess.run(
        ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pubkey_path,
         "-rawin", "-in", manifest_path, "-sigfile", signature_path],
        capture_output=True,
    )
    if r.returncode != 0:
        raise Refused("signature does not verify with the provenance key")


# TODO(homelab#44): add the scheme homelab actually signs with (raw Ed25519 is the
# assumption; ssh-keygen -Y or a sigstore bundle would slot in here).
SIGNATURE_SCHEMES = {"ed25519-openssl": verify_ed25519_openssl}


def check_signature(args):
    verifier = SIGNATURE_SCHEMES.get(args.sig_scheme)
    if verifier is None:
        raise Refused(f"unknown signature scheme {args.sig_scheme!r}")
    for label, p in (("signature", args.signature), ("provenance key", args.pubkey)):
        try:
            st = os.lstat(p)
        except OSError:
            raise Refused(f"{label} missing: {p}")
        if not stat.S_ISREG(st.st_mode) or st.st_size == 0:
            raise Refused(f"{label} is not a non-empty regular file: {p}")
    verifier(args.manifest, args.signature, args.pubkey)


def load_manifest(path):
    def no_duplicates(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            raise Refused("manifest has a duplicate key")
        return dict(pairs)

    try:
        with open(path, "rb") as f:
            m = json.loads(f.read().decode("utf-8"), object_pairs_hook=no_duplicates)
    except (OSError, UnicodeDecodeError, ValueError) as e:
        raise Refused(f"manifest unreadable: {e}")
    if not isinstance(m, dict):
        raise Refused("manifest is not a JSON object")
    return m


def check_identity(m, args):
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_sha):
        raise Refused("expected source SHA must be a full 40-hex commit sha")
    if m.get("source_sha") != args.expected_sha:
        raise Refused(f"source_sha {m.get('source_sha')!r} != expected {args.expected_sha}")
    if m.get("project") != args.expected_project:
        raise Refused(f"project {m.get('project')!r} != expected {args.expected_project}")
    if m.get("job_id") != args.expected_job:
        raise Refused(f"job_id {m.get('job_id')!r} != expected {args.expected_job}")
    if not re.fullmatch(r"[0-9]+", args.expected_build):
        raise Refused(f"expected build must be a non-negative integer, got {args.expected_build!r}")
    build = m.get("build_number")
    # type() not isinstance(): JSON true would pass isinstance(bool, int).
    if type(build) is not int or build != int(args.expected_build):
        raise Refused(f"build_number {build!r} != expected {args.expected_build}")
    issued = m.get("issued_at")
    try:
        t = datetime.datetime.fromisoformat(str(issued).replace("Z", "+00:00"))
    except ValueError:
        raise Refused(f"issued_at missing or not ISO-8601: {issued!r}")
    if t.tzinfo is None:
        raise Refused("issued_at has no timezone")
    age = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
    if age > args.max_age_seconds:
        raise Refused(f"stale job: issued_at {issued} is {int(age)}s old (max {args.max_age_seconds})")
    if age < -FUTURE_SKEW_SECONDS:
        raise Refused(f"issued_at {issued} is in the future")


def check_artifacts(m, art_dir):
    arts = m.get("artifacts")
    if not isinstance(arts, dict) or set(arts) != EXPECTED_APKS:
        raise Refused(f"manifest artifacts must be exactly {sorted(EXPECTED_APKS)}")
    for name, digest in arts.items():
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise Refused(f"manifest sha256 for {name} is malformed")
    try:
        present = set(os.listdir(art_dir))
    except OSError as e:
        raise Refused(f"artifact directory unreadable: {e}")
    missing = EXPECTED_APKS - present
    extra = present - EXPECTED_APKS
    if missing:
        raise Refused(f"missing artifacts: {sorted(missing)}")
    if extra:
        raise Refused(f"extra (unexpected) entries in artifact directory: {sorted(extra)}")
    for name in sorted(EXPECTED_APKS):
        p = os.path.join(art_dir, name)
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            raise Refused(f"{name} is a symlink, not a regular file")
        if not stat.S_ISREG(st.st_mode):
            raise Refused(f"{name} is not a regular file")
        # O_NOFOLLOW closes the lstat→open race against a swapped-in symlink.
        fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
        h = hashlib.sha256()
        with os.fdopen(fd, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != arts[name]:
            raise Refused(f"{name} sha256 hash mismatch")


def check_certs(art_dir, apksigner, pin):
    if not (os.path.isfile(apksigner) and os.access(apksigner, os.X_OK)):
        raise Refused(f"apksigner not available at {apksigner}")
    for name in sorted(EXPECTED_APKS):
        r = subprocess.run([apksigner, "verify", "--print-certs", os.path.join(art_dir, name)],
                           capture_output=True, text=True)
        digests = re.findall(r"certificate SHA-256 digest: ([0-9a-fA-F]{64})", r.stdout)
        if r.returncode != 0 or not digests:
            raise Refused(f"{name}: apksigner verify failed (unsigned or broken signature)")
        if any(d.lower() != pin for d in digests):
            raise Refused(f"{name}: signer cert {digests} is not the pinned cert {pin}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--signature", required=True, help="detached signature over the manifest bytes")
    ap.add_argument("--pubkey", required=True, help="provenance public key (PEM)")
    ap.add_argument("--sig-scheme", default="ed25519-openssl")
    ap.add_argument("--expected-sha", required=True)
    ap.add_argument("--expected-project", default="flavordrake/mobissh")
    ap.add_argument("--expected-job", required=True)
    ap.add_argument("--expected-build", required=True, help="MOBISSH_BUILD, the build ordinal B")
    ap.add_argument("--artifacts", required=True, help="directory holding exactly the release APKs")
    ap.add_argument("--max-age-seconds", type=int, default=86400)
    ap.add_argument("--expected-cert-sha256", default=PINNED_CERT_SHA256,
                    help="override for test fixtures only")
    ap.add_argument("--apksigner", default=DEFAULT_APKSIGNER)
    args = ap.parse_args()
    try:
        # Signature first: nothing in an unauthenticated manifest is acted on.
        check_signature(args)
        m = load_manifest(args.manifest)
        check_identity(m, args)
        check_artifacts(m, args.artifacts)
        check_certs(args.artifacts, args.apksigner, args.expected_cert_sha256.lower())
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 1
    print(f"VERIFIED {args.expected_project}@{args.expected_sha} build {args.expected_build} job {args.expected_job}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
