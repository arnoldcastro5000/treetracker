# Treetracker Android E2E Tests

End-to-end UI tests for the Android app, driven by **WebdriverIO + Appium + Cucumber**.
The on-device flow runs against an Android emulator; the capture-verification step drives a
desktop **Chrome** session against the Treetracker **admin panel**.

The suite is environment-agnostic: the **same tests** run against **local**, **dev**, or **production**
by changing a handful of values in `.env`. The app variant, the app package, and the admin
panel URL are all read from env (`APK_PATH`, `APP_PACKAGE`, `ADMIN_URL`).

> **Location:** this suite was relocated from `treetracker-android/e2e` to **`apps/e2e`** at the monorepo
> root (sibling of `apps/bdd`). It is a standalone npm project (`npm install` here).
> Copy `.env.example` to `.env` to configure a run. The LOCAL section below targets the **`local`**
> build (real-AWS `treetracker-local-*` env + local k3s); see the AWS `local` environment and
> Android `local` build sections in `k3s/README.md`.

---

## Prerequisites (one-time)

- **Android SDK** with `platform-tools` (adb) and `emulator`. Export it, e.g.:
  ```bash
  export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools   # your SDK path
  export ANDROID_SDK_ROOT=$ANDROID_HOME
  export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
  ```
- **A running emulator** (the suite defaults to `emulator-5554`):
  ```bash
  emulator -list-avds
  emulator -avd <your_avd> &        # or launch from Android Studio
  adb devices                        # -> emulator-5554   device
  ```
- **JDK 17** to build the app (the version CI builds with; the newest JDKs break the Android
  Gradle Plugin). On macOS, find it with:
  ```bash
  /usr/libexec/java_home -v 17
  ```
- **Node deps**:
  ```bash
  cd apps/e2e && npm install
  ```
- **ChromeDriver matching your desktop Chrome major version** (used for the admin-panel step).
  The `chromedriver` npm dep must match installed Chrome (e.g. Chrome 148 → chromedriver 148).
  If `npm install` pulled a mismatched version, install the right one:
  ```bash
  npm install chromedriver@<chrome-major>   # e.g. chromedriver@148.0.4
  ```

---

## `apps/e2e/.env` reference

| Var | Purpose |
|-----|---------|
| `APK_PATH` | Absolute path to the APK Appium installs/launches |
| `APP_PACKAGE` | Android applicationId of that APK |
| `ADMIN_URL` | Admin panel base URL the verify step drives |
| `ADMIN_USER` / `ADMIN_PASSWORD` | Admin panel login for the verify step |
| `DEVICE_NAME` | adb device id (default `emulator-5554`) |

---

## Run against **LOCAL** (default)

Local `local` build → real-AWS `treetracker-local-*` S3/SQS/Cognito → local k3s data pipeline + admin.
Signup (`02_signup_flow`) is fully offline and needs no backend; capture→verify (`03`) needs the local
pipeline + admin panel running (Phase 2).

1. Build + install the **local** APK (from `treetracker-android/`):
   ```bash
   cd ../../treetracker-android
   JAVA_HOME=<jdk-17 home> ANDROID_HOME=<your SDK path> \
     ./gradlew :app:assembleLocal
   adb -s emulator-5554 install -r app/build/outputs/apk/local/app-local.apk
   ```
2. Boot an emulator (create an AVD once, via Android Studio or `avdmanager`):
   ```bash
   emulator -avd <your_avd> &
   adb wait-for-device           # -> emulator-5554
   ```
3. Copy `.env.example` to `.env` and point it at the local build:
   ```ini
   APK_PATH=<repo>/treetracker-android/app/build/outputs/apk/local/app-local.apk
   APP_PACKAGE=org.greenstand.android.TreeTracker.local
   DEVICE_NAME=emulator-5554
   ADMIN_URL=<local admin-client URL>   # only used by 03_capture_setup
   ```
4. Run signup (back in `apps/e2e`):
   ```bash
   cd ../apps/e2e
   npm install
   npx wdio run ./wdio.conf.ts --spec features/02_signup_flow.feature
   ```

---

## Run against **DEV**

Dev build → dev backend/S3 → dev admin panel.

1. Build + install the **dev** APK:
   ```bash
   cd ../../treetracker-android
   JAVA_HOME=<jdk-17 home> ./gradlew assembleDev
   adb -s emulator-5554 install -r app/build/outputs/apk/dev/app-dev.apk
   ```
   (Requires `s3_dev_identity_pool_id` in the gitignored `treetracker.keys.properties`.)

2. `apps/e2e/.env`:
   ```ini
   ADMIN_USER=test
   ADMIN_PASSWORD=<dev-admin-password>
   ADMIN_URL=https://dev-admin.treetracker.org
   DEVICE_NAME=emulator-5554
   APK_PATH=<repo>/treetracker-android/app/build/outputs/apk/dev/app-dev.apk
   APP_PACKAGE=org.greenstand.android.TreeTracker.dev
   ```

3. Run:
   ```bash
   cd ../apps/e2e && npm test
   ```

---

## Run against **PRODUCTION**

Production-environment build → **prod** backend/S3 → **production** admin panel.
Use either build variant (same production data path):

- **`prerelease`** (recommended): production environment, **debug-signed** so it installs without a
  release keystore. Package: `org.greenstand.android.TreeTracker.prerelease`.
- **`release`**: true production, minified (R8) + **release-signed**. Needs the release keystore;
  package: `org.greenstand.android.TreeTracker`.

### Required production keys
In the gitignored `treetracker.keys.properties` (repo root):
```ini
s3_production_identity_pool_id=<real Cognito identity pool>   # REQUIRED for upload to prod S3
prod_treetracker_client_id=<real>                            # (only used by the Messages feature)
prod_treetracker_client_secret=<real>
# release builds only: signing keystore
release_store_file=<abs path to .keystore>
release_store_password=<...>
release_key_alias=<...>
release_key_password=<...>
```

### Build + install
```bash
cd ../../treetracker-android
export JAVA_HOME=<jdk-17 home>

# prerelease (debug-signed, installs as-is):
./gradlew assemblePrerelease
adb -s emulator-5554 install -r app/build/outputs/apk/prerelease/app-prerelease.apk

# OR release (signed; skip the slow lintVital tasks to speed up packaging):
./gradlew assembleRelease -x lintVitalAnalyzeRelease -x lintVitalReportRelease -x lintVitalRelease
adb -s emulator-5554 install -r app/build/outputs/apk/release/app-release.apk
```

### `apps/e2e/.env`
```ini
ADMIN_USER=test
ADMIN_PASSWORD=<prod-admin-password>
ADMIN_URL=https://admin.treetracker.org
DEVICE_NAME=emulator-5554
# prerelease:
APK_PATH=<repo>/treetracker-android/app/build/outputs/apk/prerelease/app-prerelease.apk
APP_PACKAGE=org.greenstand.android.TreeTracker.prerelease
# OR release:
# APK_PATH=<repo>/treetracker-android/app/build/outputs/apk/release/app-release.apk
# APP_PACKAGE=org.greenstand.android.TreeTracker
```

### Run
```bash
cd ../apps/e2e && npm test
```

> ⚠️ A passing run **uploads a real capture to production** S3 + admin. The capture-verify step
> polls the production `/verify` page for up to **15 minutes** (production ingest can take ~10 min).

---

## Run commands

```bash
npm test                                              # full suite (skips @skip)
npx wdio run ./wdio.conf.ts --spec features/02_signup_flow.feature     # one feature
npx wdio run ./wdio.conf.ts --spec features/03_capture_setup.feature
WDIO_TAGS="@smoke" npm test                           # filter by Cucumber tag
```

Active scenarios: `02_signup_flow` (language → signup → dashboard) and `03_capture_setup`
(capture → upload → admin `/verify` confirmation). Others are tagged `@skip`.

---

## Run in GitHub Actions

Two workflows run this suite in CI. Neither needs a local emulator; CI is the normal way to run
the full pipeline.

**`android-e2e-route2.yml`** (Android E2E, Route 2, co-located) is the full run: it stands up the
whole backend (k3d capture pipeline + LocalStack) and an accelerated emulator in one job, then
drives the real `local` APK through capture → upload → admin `/verify`. A full run takes roughly
25 minutes. Two triggers:

- Manual dispatch, with a `stage` input (1 = coexistence, 2 = upload fidelity, 3 = full `/verify`;
  default 3):
  ```bash
  gh workflow run android-e2e-route2.yml --ref <branch> -f stage=3
  gh run list --workflow android-e2e-route2.yml
  gh run watch <run-id>
  gh run download <run-id>      # evidence artifact: video, screenshots, logcat, reports
  ```
- A push to any branch whose name contains `route2-e2e` starts the full run automatically (a
  docs-only push is skipped). Pick a branch name without that pattern when you do not want CI.

The run summary starts with the Capture Journey report: a table that traces the capture from the
Android UI through the backend pipeline to `/verify` and names the hop where a failed run stopped.

**`android-e2e.yml`** (Android E2E) is the fast offline check: it runs `02_signup_flow` on an
emulator with no backend. It triggers on manual dispatch (a `spec` input selects the feature
file), on a push to a branch whose name contains `android-e2e`, and on PRs that touch `apps/e2e`,
`treetracker-android`, or the workflow itself:

```bash
gh workflow run android-e2e.yml --ref <branch> -f spec=02_signup_flow.feature
```

---

## Notes & gotchas

- **Admin ingest latency**: on production the capture can take ~10 min to appear on `/verify`; the
  verify step polls up to 15 min (`utils/admin.ts`), and the Cucumber/Appium timeouts in
  `wdio.conf.ts` are sized to match.
- **Verify approach**: the step opens the **top** capture row's detail dialog and matches a unique
  note ("fingerprint") stamped into the captured tree. This is reliable on the sparse dev `/verify`;
  on the high-volume production queue it depends on the capture being near the top (and the default
  filter), so the production verify step can be flaky.
- **ChromeDriver / Chrome mismatch** is the most common admin-step failure; keep them on the same
  major version.
- **`noReset: true`**: app data persists between scenarios. `03` relies on a user signed up by `02`
  (run order is alphabetical, so `02` precedes `03`).
- Test artifacts (videos, screenshots, admin-debug dumps) land in `apps/e2e/test-artifacts/`.
