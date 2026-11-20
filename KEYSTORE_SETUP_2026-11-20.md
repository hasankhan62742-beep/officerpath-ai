# H1 Keystore Setup — OfficerPath AI v2.0.1 (2026-11-20)

Owner approved the signed v2.0.1 build with a one-time uninstall/reinstall
(20 Nov ~10:55 PKT). This report covers the permanent keystore, the repo
secrets, the CI workflow change, and the version bump. No APK was built
here — the v2.0.1 APK is produced by CI on the next push/release, after
the parser fixes land.

## 1. The permanent keystore (created once, never lose it)

- **Location (outside the repo, never committed):**
  `~/workspace/officerpath-ai-keystore/officerpath-release.keystore`
  (2,818 bytes, chmod 600; directory chmod 700)
- **Alias:** `officerpath`
- **Key:** RSA 2048, SHA256withRSA, self-signed
- **Validity:** 2026-11-20 → 2054-04-07 (10,000 days, ~27.4 years)
- **Distinguished name:** CN=Muhammad Abdul Qadeer, OU=Qadeer Automations,
  O=Qadeer Automations, L=Jatoi, ST=Punjab, C=PK
- **SHA-256 fingerprint:**
  `04:60:61:E3:98:2B:6A:5D:D5:57:C8:E0:C0:D6:45:CA:2F:CF:10:D0:E6:9D:B5:7F:FB:6F:26:3F:8D:45:71:3C`
  (Verify any future APK against this fingerprint to prove it was signed
  with this key.)
- **Passwords:** the only on-disk copy is the sealed file
  `~/workspace/officerpath-ai-keystore/README` (chmod 600, outside the
  repo). Password values appear NOWHERE in the repo, NOWHERE in this
  report, and were never passed on a command line (keytool read them
  from temp files deleted immediately after use).
- **Generated with:** `/home/hatch/jdk17/bin/keytool` (Temurin 17.0.21).
  No JDK was installed on the VM before this — the bundled JDK at
  `~/jdk17` was found and used.

### PKCS12 note (why one password, not two)

JDK 17's default keystore type is PKCS12, which does NOT support
different store and key passwords — keytool warns "Different store and
key passwords not supported for PKCS12 KeyStores. Ignoring
user-specified -keypass value." So ONE strong random password (48 hex
chars, `secrets.token_hex(24)`) protects both the store and the key,
and the two repo secrets `KEYSTORE_PASSWORD` and `KEY_PASSWORD` carry
the same value. This is recorded in the keystore README as well. Do
not "fix" it by changing only one of them — the build would fail.

## 2. GitHub repo secrets (set + verified, names only)

Repo: `hasankhan62742-beep/officerpath-ai`. Set via the existing
`custom.github-pat` credential through `github_release.py`'s
`set_secret()` (SealedBox encryption, same as the Supabase secrets).
Verified afterwards by listing secret names — all four present, plus
the existing `SUPABASE_URL` + `SUPABASE_ANON_KEY`:

- `ANDROID_KEYSTORE_BASE64` — base64 of the keystore file (3,760 chars)
- `KEYSTORE_PASSWORD`
- `KEY_ALIAS` — `officerpath`
- `KEY_PASSWORD` — same value as `KEYSTORE_PASSWORD` (PKCS12, see §1)

## 3. CI workflow change (`.github/workflows/build-apk.yml`)

- New step **"Prepare release signing key"** (before the build): decodes
  `ANDROID_KEYSTORE_BASE64` to `android/app/officerpath-release.keystore`
  and writes `android/key.properties` (storePassword / keyPassword /
  keyAlias / storeFile with an absolute path) from the secrets.
  Both files are created fresh on every run, never enter the repo
  (both git-ignored), and GitHub Actions masks secret values in logs.
- Build step renamed **"Build arm64 release APK"**: now
  `flutter build apk --release --split-per-abi` (was `--debug`).
- Rename step updated: source is now `app-arm64-v8a-release.apk`
  (was `app-arm64-v8a-debug.apk`).
- Unchanged: `flutter analyze` + `flutter test` gates, the SHA-256
  sidecar step (`officerpath-ai-<version>-arm64.apk.sha256`, M3),
  the workflow-artifact upload, and the release-attach step.
- Header comments updated to describe release signing and the
  one-time reinstall.
- Verified: YAML parses (`yaml.safe_load`, 12 steps); the signing
  steps reference only `${{ secrets.* }}` and `$VAR` references —
  no literal password anywhere in the workflow; no keystore or
  `key.properties` file exists in the working tree.

## 4. Version bump (`pubspec.yaml`)

- `version: 2.0.0+5000` → **`version: 2.0.1+5100`**
- Arm64 versionCode: 5100 + 2000 (split-per-abi) = **7100**, which
  exceeds v2.0.0's 7000 — the version code alone would allow
  installing over v2.0.0. The blocker is the SIGNING KEY, not the
  version code: v2.0.0 was debug-signed, so Android still refuses
  and the one-time uninstall/reinstall is required.

## 5. Verification done in this pass

- Keystore verified with `keytool -list -v` (alias, validity,
  fingerprint as above).
- All four secrets listed by name via the GitHub API after setting.
- Workflow YAML parses; signing steps contain no literal passwords.
- `flutter analyze` (20 Nov, after the edits): **20 issues, all
  info-level `avoid_print` in `test/ppsc66_baseline_test.dart`** (the
  baseline agent's harness file) — zero errors, zero warnings, none
  in any file touched here. The tree compiles at this moment.
- No files touched in `lib/`, `test/`, `supabase/`, or `admin/`.
  Only `pubspec.yaml` and `.github/workflows/build-apk.yml` changed.
  No commit, push, release, or CI trigger was made.

## 6. Honest limits — what this does NOT do yet

1. **No v2.0.1 APK exists yet.** The build happens on the next push /
   CI run (release published or `v2.0.1` tag), after the parser fixes
   land. This pass only prepared the key, the secrets, the workflow,
   and the version number.
2. **The one-time reinstall is still required** for every v1.2.0 and
   v2.0.0 install, because the new key matches neither old key
   (v2.0.0's key was ephemeral and is lost; v1.2.0 was debug-signed).
   The v2.0.1 update email must carry the uninstall-first instruction.
   Local phone data is lost on reinstall; the Supabase account
   (email, Premium status) survives.
3. **If the keystore file + passwords are ever lost, ALL future
   builds need another reinstall** — there is no recovery, and Play
   would require a new package name. Keep TWO copies in two places
   (this VM + an encrypted USB / password-manager secure note).
   The only on-disk copy of the passwords today is the sealed README
   in `~/workspace/officerpath-ai-keystore/`.
4. **CI end-to-end is untested.** The first release-signed build is
   the proof: it must produce `app-arm64-v8a-release.apk`, the
   fingerprint must match §1, and the `.sha256` sidecar must verify.
   If the workflow fails on the keystore step, the failure will be
   visible in the Actions run log (secrets masked).

## Second backup (parent, 20 Nov 2026 ~11:35 PKT)
- Second copy verified byte-identical (sha256 match on both files): `~/workspace/officerpath-ai-keystore-backup/` — keystore + sealed README, dir chmod 700, files chmod 600.
- Two on-disk copies now exist: `~/workspace/officerpath-ai-keystore/` (primary) and `~/workspace/officerpath-ai-keystore-backup/`. Both outside the repo tree; neither is ever committed or pushed.
