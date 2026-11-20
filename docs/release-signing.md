# OfficerPath AI v2.0.0 — Release Signing & Play Store Build

How the v2.0.0 APK/AAB is signed, what happens to existing installs,
and exactly how the GitHub self-updater is stripped for a Play build.

## 1. The keystore (create ONCE, never lose it)

The release keystore does NOT exist yet. No release-key build has ever
been made for this app — every APK shipped so far (v1.2.0, and the CI
debug APKs) is signed with the **debug key**. The owner creates the
release keystore once, on his own machine, with:

```bash
keytool -genkey -v -keystore ~/officerpath-release.keystore \
  -alias officerpath -keyalg RSA -keysize 2048 -validity 10000
```

`keytool` asks for a store password, a key password, and owner details
(name / organisation / city / country). Use a strong store password and
a DIFFERENT strong key password, and write both down somewhere safe
(password manager, not a chat message).

Then create `android/key.properties` (NEVER commit it — it is in
`.gitignore`, alongside `*.keystore` / `*.jks`):

```
storePassword=<your store password>
keyPassword=<your key password>
keyAlias=officerpath
storeFile=<absolute path to officerpath-release.keystore>
```

`android/app/build.gradle.kts` already wires this up: when
`key.properties` exists, the `release` signing config uses it; when it
does NOT exist and a Release task is requested, the build FAILS FAST
with `GradleException("Release signing key missing ...")` instead of
silently signing with the debug key (audit m5). Debug builds are
unaffected.

### Backup warning — read this before you build anything release-signed

**If the keystore file or its passwords are lost, the app can NEVER be
updated on Play again under the same package name** — Google Play
requires every update to be signed with the SAME key, and there is no
reset. Losing it means publishing a brand-new app (new package name,
new listing, all users lost). Keep TWO copies in two places:

1. The original file, e.g. `~/officerpath-release.keystore`.
2. An encrypted backup (USB drive / password manager secure note /
   a second computer) — plus the two passwords in the password manager.

Play's "App signing by Google Play" (upload key) softens this AFTER the
first Play upload (Google holds the app-signing key; the upload key can
be reset), but the upload keystore itself must still be kept safe.

## 2. What a release-key build does to existing installs

Android installs an update OVER an existing app only when both APKs
share the same signing key. Consequences, stated plainly:

| From → To | Result |
|---|---|
| debug-signed v1.2.0 → debug-signed v2.0.0 (GitHub CI) | Installs over the old app. Books, history and settings are kept. versionCode: v1.3.0+4004 arm64 = 6004, v2.0.0+5000 arm64 = 7000 (split-per-abi adds 2000 for arm64) — both > v1.2.0's 4002. |
| debug-signed v1.2.0 → release-key v2.0.0 | **CANNOT install over it.** Android refuses (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). The user must UNINSTALL v1.2.0 first — and that DELETES all local data: books, test history, streak. There is no way around this; it is Android's signing rule. |
| release-key v2.0.0 → later release-key builds (same keystore) | Installs over, data kept. This is the steady state once the keystore exists. |
| Any build → Play Store build (same release key as upload key) | Play delivers updates itself; data kept as long as the signing key matches. |

**Decision for v2.0.0:** ship the GitHub release as the debug-signed
CI APK (same as v1.3.0 was planned), so existing v1.2.0 users update
in place with no data loss. Create the release keystore NOW (this doc),
but switch the distributed build to release-signed only at the Play
launch — and when that happens, the launch email / post must say
plainly that Play users install fresh (their v1/v2 sideload data does
not carry over). The v2.0 update email already carries a
finalize-at-release-time install note for exactly this reason (see
`~/workspace/goals/officerpath-access-request-replies/hidden_files/v1.3-update-email-pending.md`).

## 3. Updater gating — how self-update is switched off for Play

Play forbids apps that update themselves outside Play. The gate is
`AppUpdateService.updateChecksAllowed` (`lib/services/app_update_service.dart`):

- GitHub builds (default): `--dart-define` `PLAY_BUILD` is unset, so
  `selfUpdateEnabled` is `true` and `checkForUpdate()` runs.
- Play builds: build with `--dart-define=PLAY_BUILD=true` and
  `selfUpdateEnabled` becomes `false`; `checkForUpdate()` returns
  `null` immediately, so BOTH call sites do nothing:
  - Home launch check (`lib/screens/home_screen.dart` →
    `maybePromptForUpdate`, which calls `checkForUpdate()`),
  - About → "Check for updates" (`lib/widgets/update_prompt.dart` →
    `checkForUpdatesManually`, which first checks the flag and shows
    "Updates Play Store se aate hain" instead of the checking dialog).
- The gating logic is covered by tests in
  `test/app_update_service_test.dart` (`updateChecksAllowed` group):
  Play (`playBuild: true`) → no check; GitHub (`playBuild: false`) →
  check proceeds; default (no dart-define) → GitHub behaviour.
- Default stays TRUE for GitHub builds. Nobody has to remember to flip
  anything for the normal release path.

## 4. Stripping REQUEST_INSTALL_PACKAGES for a Play build

The permission lives in the main manifest
(`android/app/src/main/AndroidManifest.xml`) because the GitHub
self-updater needs it (the system installer for a downloaded APK).
It MUST NOT ship in a Play build: Play policy forbids requesting it
for self-updates, and a Play build never uses the updater (see §3).

There is no `dart-define` for a manifest permission — it is stripped
with a **build flavor**. At Play time, apply exactly this (NOT done
yet — the GitHub CI build must keep working unchanged until then):

1. In `android/app/build.gradle.kts`, inside the `android { }` block,
   add a flavor dimension with two flavors:

   ```kotlin
   flavorDimensions += "store"
   productFlavors {
       create("github") {
           dimension = "store"
       }
       create("play") {
           dimension = "store"
       }
   }
   ```

2. Create `android/app/src/play/AndroidManifest.xml` containing ONLY
   the removal (the main manifest is still merged in):

   ```xml
   <manifest xmlns:android="http://schemas.android.com/apk/res/android"
       xmlns:tools="http://schemas.android.com/tools">
       <uses-permission
           android:name="android.permission.REQUEST_INSTALL_PACKAGES"
           tools:node="remove" />
   </manifest>
   ```

3. Build the Play artifact with the flavor + the Play dart-define:

   ```bash
   flutter build appbundle --release --flavor play \
     --dart-define=PLAY_BUILD=true \
     --dart-define=SUPABASE_URL=... \
     --dart-define=SUPABASE_ANON_KEY=...
   ```

   (An AAB, not an APK — Play requires the Android App Bundle.)
   The GitHub CI workflow (`.github/workflows/build-apk.yml`) keeps
   building WITHOUT `--flavor`, i.e. the `github` flavor path, so the
   sideload APK is unaffected.

4. Verify the strip before uploading: unzip the AAB (or the APK from
   `bundletool`), dump the manifest (`aapt2 dump xmltree`) and confirm
   `REQUEST_INSTALL_PACKAGES` is absent and `POST_NOTIFICATIONS` is
   still present.

Why this is documented, not implemented, in v2.0.0: adding the flavor
dimension changes the DEFAULT build (a bare `flutter build apk` would
fail without `--flavor`), which would break the CI workflow that ships
v2.0.0. The flavor lands with the Play launch, together with Play
Billing. Until then the GitHub APK keeps the permission — correctly,
because it is the updater that needs it.

## 5. Release checklist (Play launch, in order)

1. Create the keystore + `key.properties` (§1) and back both up.
2. Apply the `play` flavor + manifest strip (§4).
3. Build the AAB (§4 step 3) — the build fails fast without the keystore.
4. Create the Play Console account ($25 one-time) — see AUDIT_REPORT.md
   § v2.0 Play checklist (closed testing: 12 testers / 14 days).
5. Upload the AAB to the Internal Testing track first, then Closed
   Testing, then Production. Fill in the data-safety form from
   `docs/play-privacy-policy.md` (copy the answers verbatim) and link
   the privacy policy (host `docs/play-privacy-policy.md` content as a
   public page — Play needs a URL, not a repo file).
6. Play Billing comes LATER (after the free launch proves demand).
   Nothing in v2 blocks it: `PremiumPlan.playStoreProductId` values
   (`officerpath_premium_1month` / `_2months` / `_1year`) are already
   the product ids to create in Play Console, and
   `SubscriptionService.grantPremium(plan)` is the single call the
   billing layer makes after a verified purchase (see the wiring steps
   in `lib/services/billing_service.dart`).
