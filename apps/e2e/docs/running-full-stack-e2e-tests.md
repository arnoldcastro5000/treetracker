# Run the full-stack Android E2E tests

This guide shows you how to run the full-stack Android end-to-end (E2E) tests. It is a task recipe.
For the environment reference and the other run targets (dev, production), read the
[E2E suite README](../README.md).

## What this covers

The full-stack E2E test drives the real `local` Android APK on an emulator through the app user
interface, with WebdriverIO, Appium, and Cucumber. It runs against the whole local backend: the k3d
Kubernetes capture pipeline, a LocalStack S3 store, and the admin panel, all stood up on one machine.
It exercises the complete loop: capture, upload, pipeline ingest, Postgres, and admin verify. This is
the `03_capture_setup` scenario.

The settled name for this test is the "full-stack E2E" (co-located, because the backend and the
emulator run together in one job). The older internal alias is "Route 2".

One scenario is different: `02_signup_flow` is fully offline. It needs no backend, so you can run it
against the emulator alone.

## Before you start

You need:

- The Java Development Kit, version 17.
- The Android SDK, with an emulator. Use an Android Virtual Device (AVD) on API level 30, profile
  `pixel_5`. This matches CI.
- Node.js, version 20.
- Docker, plus the k3d cluster tools that the local stack needs. See the
  [k3s stand-up README](../../../k3s/README.md).
- The local admin panel, for the `03` verify step.
- Google Chrome, for the desktop `/verify` step (the verify step drives Chrome through chromedriver).

Install the E2E dependencies once, from `apps/e2e`:

```bash
npm install
```

Install Appium and the UiAutomator2 driver globally, because the Appium service spawns a bare
`appium` process:

```bash
npm install -g appium@2.19.0
appium driver install uiautomator2@3.10.0
```

## Run the tests locally

You can run the offline sign-up scenario without a backend, or the full capture-to-verify loop with
the local stack up.

### Offline sign-up (no backend)

1. Build and install the `local` APK, from `treetracker-android`:

   ```bash
   cd ../../treetracker-android
   JAVA_HOME=<jdk-17-home> ANDROID_HOME=<your-sdk-path> ./gradlew :app:assembleLocal
   adb -s emulator-5554 install -r app/build/outputs/apk/local/app-local.apk
   ```

2. Boot the emulator and wait for it:

   ```bash
   emulator -avd <your-avd> &
   adb wait-for-device
   ```

3. Copy `apps/e2e/.env.example` to `apps/e2e/.env` and point it at the `local` build:

   ```ini
   APK_PATH=<repo>/treetracker-android/app/build/outputs/apk/local/app-local.apk
   APP_PACKAGE=org.greenstand.android.TreeTracker.local
   DEVICE_NAME=emulator-5554
   ```

4. Run the sign-up scenario, from `apps/e2e`:

   ```bash
   npx wdio run ./wdio.conf.ts --spec features/02_signup_flow.feature
   ```

### Full capture-to-verify loop (local stack required)

1. Stand up the local backend, from the repository root. This step is heavy: it builds the pipeline
   images and boots a k3d cluster and LocalStack. Read the
   [k3s stand-up README](../../../k3s/README.md) first.

   ```bash
   ./k3s/up.sh capture
   ./k3s/up.sh verify capture
   ```

2. Build and install the `local` APK, and set `apps/e2e/.env` as in the offline steps above. Add the
   local admin panel URL, which the verify step uses:

   ```ini
   ADMIN_URL=<local admin-client URL>
   ```

3. Run the capture-to-verify scenario, from `apps/e2e`:

   ```bash
   npx wdio run ./wdio.conf.ts --spec features/03_capture_setup.feature
   ```

4. Tear the stack down when you finish:

   ```bash
   ./k3s/down.sh
   ```

## Run the tests in CI

CI is the normal way to run the full pipeline, because the local stand-up is heavy. The workflow file
is `.github/workflows/android-e2e-route2.yml`. It stands up the whole backend and an emulator in one
job, then drives the real `local` APK end to end.

Run it by manual dispatch. The `stage` input selects the first-green stage (1 coexistence, 2 upload
fidelity, 3 full `/verify`; the default is 3):

```bash
gh workflow run android-e2e-route2.yml -f stage=3
gh run list --workflow android-e2e-route2.yml
gh run watch <run-id>
```

A push to any branch also starts the run (a docs-only push is skipped).

## Check the result

For a local run, WebdriverIO prints the Cucumber scenario result. A pass shows the scenario green.

For a CI run, read the run summary page. It opens with the stage and a PASS or FAIL verdict, then the
Capture Journey report: a table that traces the capture from the app user interface, through the
backend pipeline, to `/verify`, and names the hop where a failed run stopped. Download the evidence
with:

```bash
gh run download <run-id>   # video, screenshots, logcat, and reports
```

## If it fails

- If a capture stops at the camera step, read [Emulator camera limitation](emulator-camera-limitation.md).
  The emulator camera has a known limit.
- If the CI run fails early during stand-up, re-run it. The heavy stand-up can flake before the tests
  run; a re-run is the normal recovery.
- If the desktop `/verify` step fails to start a Chrome session, rebuild chromedriver to match your
  installed Chrome major version:

  ```bash
  cd apps/e2e && npm rebuild chromedriver
  ```

## See also

- [E2E suite README](../README.md): the environment reference, and the dev and production run targets.
- [k3s stand-up README](../../../k3s/README.md): the local backend stand-up.
